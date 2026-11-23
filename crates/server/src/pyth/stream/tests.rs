// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
use super::*;

fn hub() -> Hub {
    Hub::new(
        &[1, 11],
        PythStreamConfig {
            allowed_origins: vec!["https://app.example".into()],
            trusted_proxy_hops: 0,
        },
    )
}
fn frame(timestamp: u64, price: Value) -> Value {
    json!({"type":"streamUpdated", "parsed":{"timestampUs":timestamp.to_string(), "priceFeeds":[{
        "priceFeedId":1,"price":price,"exponent":-8,"feedUpdateTimestamp":timestamp - 10
    }]}})
}

#[tokio::test]
async fn preserves_repeated_prices_and_exact_boundary_but_drops_duplicates() {
    let hub = hub();
    let mut events = hub.events.subscribe();
    let boundary = 1_795_025_640_000_000;
    hub.accept(&frame(boundary - 200_000, json!("9512345678901")))
        .unwrap();
    hub.accept(&frame(boundary, json!("9512345678901")))
        .unwrap();
    hub.accept(&frame(boundary, json!("999"))).unwrap();
    hub.accept(&frame(boundary - 200_000, json!("999")))
        .unwrap();
    let (_, _, first) = events.recv().await.unwrap();
    assert_eq!(first["timestamp_us"], (boundary - 200_000).to_string());
    assert_eq!(events.recv().await.unwrap().2["stale"], false);
    let (_, _, second) = events.recv().await.unwrap();
    assert_eq!(second["timestamp_us"], "1795025640000000");
    assert_eq!(second["price"], "9512345678901");
    assert_eq!(second["feed_update_us"], "1795025639999990");
    assert!(matches!(
        events.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn missing_price_does_not_refresh_health_or_emit_zero() {
    let hub = hub();
    let mut events = hub.events.subscribe();
    hub.accept(&frame(1_000_000, Value::Null)).unwrap();
    assert!(hub.inner.lock().unwrap().feeds[&1].latest.is_none());
    assert!(matches!(
        events.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn signals_stale_once_and_recovers_only_on_advancing_frame() {
    let hub = hub();
    hub.accept(&frame(1_000_000, json!("100"))).unwrap();
    let mut events = hub.events.subscribe();
    hub.inner
        .lock()
        .unwrap()
        .feeds
        .get_mut(&1)
        .unwrap()
        .received = Instant::now() - Duration::from_secs(3);
    hub.mark_stale();
    hub.mark_stale();
    assert_eq!(events.recv().await.unwrap().2["stale"], true);
    hub.accept(&frame(1_000_000, json!("100"))).unwrap();
    assert!(hub.inner.lock().unwrap().feeds[&1].stale);
    hub.accept(&frame(1_200_000, json!("100"))).unwrap();
    assert_eq!(events.recv().await.unwrap().2["type"], "price");
    assert_eq!(events.recv().await.unwrap().2["stale"], false);
    assert!(matches!(
        events.try_recv(),
        Err(broadcast::error::TryRecvError::Empty)
    ));
}

#[tokio::test]
async fn bounded_broadcast_reports_a_slow_reader_without_delaying_fast_reader() {
    let hub = hub();
    let mut slow = hub.events.subscribe();
    let mut fast = hub.events.subscribe();
    for i in 1..=300 {
        hub.accept(&frame(i * 200_000, json!("100"))).unwrap();
        assert_eq!(fast.recv().await.unwrap().2["type"], "price");
        if i == 1 {
            fast.recv().await.unwrap();
        }
    }
    assert!(matches!(
        slow.recv().await,
        Err(broadcast::error::RecvError::Lagged(_))
    ));
}

async fn server(hub: Hub) -> (String, tokio::task::JoinHandle<()>) {
    let config = crate::pyth::PythProConfig {
        allowed_feed_ids: vec![1, 11],
        ..Default::default()
    };
    let mut proxy = crate::pyth::PythProxy::new(
        url::Url::parse("http://localhost").unwrap(),
        Some("test".into()),
        config,
    )
    .unwrap();
    proxy.stream = Some(hub);
    serve(proxy).await
}

async fn serve(proxy: crate::pyth::PythProxy) -> (String, tokio::task::JoinHandle<()>) {
    let router = axum::Router::new()
        .route("/ws", axum::routing::get(upgrade))
        .with_state(proxy);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        axum::serve(
            listener,
            router.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap();
    });
    (format!("ws://{address}/ws"), task)
}
async fn receive<S>(socket: &mut tokio_tungstenite::WebSocketStream<S>) -> Value
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let message = timeout(Duration::from_secs(2), socket.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    serde_json::from_str(message.to_text().unwrap()).unwrap()
}

#[tokio::test]
async fn browser_receives_cache_live_frames_rejections_and_unsubscribe() {
    let hub = hub();
    hub.accept(&frame(1_000_000, json!("100"))).unwrap();
    let (url, task) = server(hub.clone()).await;
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("Origin", "https://app.example".parse().unwrap());
    let (mut socket, _) = tokio_tungstenite::connect_async(request).await.unwrap();
    socket
        .send(UpstreamMessage::Text(
            json!({"type":"subscribe", "feed_ids":[1,999]})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    let ack = receive(&mut socket).await;
    assert_eq!(ack["feed_ids"], json!([1]));
    assert_eq!(ack["rejected"], json!([999]));
    assert_eq!(receive(&mut socket).await["timestamp_us"], "1000000");
    assert_eq!(receive(&mut socket).await["stale"], false);
    hub.accept(&frame(1_200_000, json!("101"))).unwrap();
    assert_eq!(receive(&mut socket).await["price"], "101");
    socket
        .send(UpstreamMessage::Text(
            json!({"type":"unsubscribe", "feed_ids":[1]})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    assert_eq!(receive(&mut socket).await["type"], "unsubscribed");
    socket.close(None).await.unwrap();
    task.abort();
}

#[tokio::test]
async fn redundant_upstream_delivers_after_one_connection_closes() {
    async fn source() -> (
        String,
        tokio::sync::mpsc::UnboundedSender<Value>,
        tokio::sync::oneshot::Receiver<()>,
        tokio::task::JoinHandle<()>,
    ) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (sender, mut frames) = tokio::sync::mpsc::unbounded_channel::<Value>();
        let (ready, ready_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_hdr_async(
                tcp,
                |request: &tokio_tungstenite::tungstenite::handshake::server::Request, response| {
                    assert_eq!(request.headers()["authorization"], "Bearer test-token");
                    Ok(response)
                },
            )
            .await
            .unwrap();
            let request: Value =
                serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                    .unwrap();
            assert_eq!(request["channel"], "fixed_rate@200ms");
            assert_eq!(request["formats"], json!([]));
            assert_eq!(request["deliveryFormat"], "json");
            ready.send(()).unwrap();
            while let Some(value) = frames.recv().await {
                socket
                    .send(UpstreamMessage::Text(value.to_string().into()))
                    .await
                    .unwrap();
            }
            socket.close(None).await.unwrap();
        });
        (format!("ws://{address}"), sender, ready_rx, task)
    }
    let hub = hub();
    let mut events = hub.events.subscribe();
    let (url1, frames1, ready1, server1) = source().await;
    let (url2, frames2, ready2, server2) = source().await;
    let first_hub = hub.clone();
    let first = tokio::spawn(async move { first_hub.upstream(&url1, "test-token").await });
    let second_hub = hub.clone();
    let second = tokio::spawn(async move { second_hub.upstream(&url2, "test-token").await });
    timeout(Duration::from_secs(2), async {
        ready1.await.unwrap();
        ready2.await.unwrap();
    })
    .await
    .unwrap();
    frames1.send(frame(1_000_000, json!("100"))).unwrap();
    assert_eq!(
        timeout(Duration::from_secs(2), events.recv())
            .await
            .unwrap()
            .unwrap()
            .2["timestamp_us"],
        "1000000"
    );
    events.recv().await.unwrap(); // recovered status
    drop(frames1);
    assert!(timeout(Duration::from_secs(2), first)
        .await
        .unwrap()
        .unwrap()
        .is_err());
    frames2.send(frame(1_000_000, json!("100"))).unwrap(); // redundant delivery
    frames2.send(frame(1_200_000, json!("101"))).unwrap();
    assert_eq!(
        timeout(Duration::from_secs(2), events.recv())
            .await
            .unwrap()
            .unwrap()
            .2["timestamp_us"],
        "1200000"
    );
    second.abort();
    server1.abort();
    server2.abort();
}

#[tokio::test]
async fn per_ip_cap_rejects_extra_connections_and_releases_permits() {
    let hub = hub();
    let (url, task) = server(hub.clone()).await;
    let request = || {
        let mut request = url.clone().into_client_request().unwrap();
        request
            .headers_mut()
            .insert("Origin", "https://app.example".parse().unwrap());
        request
    };
    let mut sockets = Vec::new();
    for _ in 0..MAX_PER_IP {
        sockets.push(tokio_tungstenite::connect_async(request()).await.unwrap().0);
    }
    let error = tokio_tungstenite::connect_async(request())
        .await
        .unwrap_err();
    let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
        panic!("expected HTTP rejection")
    };
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(hub.metrics.clients.get(), 20);
    drop(sockets);
    timeout(Duration::from_secs(2), async {
        while hub.metrics.clients.get() != 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    assert!(hub.inner.lock().unwrap().connections.is_empty());
    let (mut socket, _) = tokio_tungstenite::connect_async(request()).await.unwrap();
    socket.close(None).await.unwrap();
    task.abort();
}

#[test]
fn rejects_bad_origins_and_proxy_configuration() {
    for origin in ["*", "https://app.example/path", "https://app.example/"] {
        let config = crate::pyth::PythProConfig {
            stream: Some(PythStreamConfig {
                allowed_origins: vec![origin.into()],
                trusted_proxy_hops: 0,
            }),
            ..Default::default()
        };
        assert!(crate::pyth::PythProxy::new(
            url::Url::parse("http://localhost").unwrap(),
            None,
            config
        )
        .is_err());
    }
}

#[tokio::test]
async fn foreign_origin_rejected_before_upgrade() {
    let (url, task) = server(hub()).await;
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("Origin", "https://foreign.example".parse().unwrap());
    let error = tokio_tungstenite::connect_async(request).await.unwrap_err();
    let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
        panic!("expected HTTP rejection")
    };
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    task.abort();
}

#[tokio::test]
async fn disabled_stream_returns_503_without_upstream_tasks() {
    let proxy = crate::pyth::PythProxy::new(
        url::Url::parse("http://localhost").unwrap(),
        None,
        Default::default(),
    )
    .unwrap();
    assert!(proxy.start_stream(&Registry::new()).unwrap().is_none());
    let (url, task) = serve(proxy).await;
    let error = tokio_tungstenite::connect_async(url).await.unwrap_err();
    let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
        panic!("expected HTTP rejection")
    };
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    task.abort();
}

#[tokio::test]
async fn trusted_proxy_uses_the_verified_suffix_not_a_spoofed_prefix() {
    let mut hub = hub();
    hub.config.trusted_proxy_hops = 2;
    hub.inner
        .lock()
        .unwrap()
        .connections
        .insert("203.0.113.10".parse().unwrap(), MAX_PER_IP);
    let (url, task) = server(hub).await;
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("Origin", "https://app.example".parse().unwrap());
    request.headers_mut().insert(
        "X-Forwarded-For",
        "6.6.6.6, 203.0.113.10, 35.1.1.1".parse().unwrap(),
    );
    let error = tokio_tungstenite::connect_async(request).await.unwrap_err();
    let tokio_tungstenite::tungstenite::Error::Http(response) = error else {
        panic!("expected HTTP rejection")
    };
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    task.abort();
}
