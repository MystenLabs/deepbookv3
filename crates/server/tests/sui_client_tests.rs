use std::sync::Arc;
use tokio::sync::OnceCell;
use url::Url;

/// A mock structure that mimics the SuiClient caching behavior in AppState
/// to test the OnceCell pattern without requiring actual RPC connections.
struct MockAppState {
    rpc_url: Url,
    sui_client: Arc<OnceCell<MockSuiClient>>,
    init_count: Arc<std::sync::atomic::AtomicU32>,
}

/// A mock SuiClient for testing purposes
#[derive(Debug, Clone)]
struct MockSuiClient {
    id: u64,
}

impl MockSuiClient {
    fn new() -> Self {
        // Use a random ID to verify it's the same instance
        Self {
            id: rand::random::<u64>(),
        }
    }
}

impl MockAppState {
    fn new(rpc_url: &str) -> Self {
        Self {
            rpc_url: Url::parse(rpc_url).expect("Invalid URL"),
            sui_client: Arc::new(OnceCell::new()),
            init_count: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        }
    }

    /// Simulates the sui_client() method from AppState
    async fn sui_client(&self) -> Result<&MockSuiClient, &'static str> {
        self.sui_client
            .get_or_try_init(|| async {
                self.init_count
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                // Simulate async initialization
                tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                Ok::<MockSuiClient, &'static str>(MockSuiClient::new())
            })
            .await
    }

    /// Simulates a failing client initialization
    async fn sui_client_failing(&self) -> Result<&MockSuiClient, &'static str> {
        self.sui_client
            .get_or_try_init(|| async {
                self.init_count
                    .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Err("Failed to connect to RPC")
            })
            .await
    }

    fn get_init_count(&self) -> u32 {
        self.init_count.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[tokio::test]
async fn test_client_lazy_initialization() {
    let state = MockAppState::new("https://example.com");

    // Client should not be initialized yet
    assert!(state.sui_client.get().is_none());
    assert_eq!(state.get_init_count(), 0);

    // First call should initialize the client
    let client = state.sui_client().await.expect("Should succeed");
    assert!(state.sui_client.get().is_some());
    assert_eq!(state.get_init_count(), 1);

    // Verify we got a valid client
    assert!(client.id > 0);
}

#[tokio::test]
async fn test_client_reuse_across_multiple_calls() {
    let state = MockAppState::new("https://example.com");

    // Make multiple sequential calls
    let client1 = state.sui_client().await.expect("Should succeed");
    let id1 = client1.id;

    let client2 = state.sui_client().await.expect("Should succeed");
    let id2 = client2.id;

    let client3 = state.sui_client().await.expect("Should succeed");
    let id3 = client3.id;

    // All calls should return the same client instance (same ID)
    assert_eq!(id1, id2);
    assert_eq!(id2, id3);

    // Initialization should only happen once
    assert_eq!(state.get_init_count(), 1);
}

#[tokio::test]
async fn test_concurrent_requests_share_same_client() {
    let state = Arc::new(MockAppState::new("https://example.com"));

    // Spawn multiple concurrent tasks that all try to get the client
    let mut handles = Vec::new();
    for _ in 0..10 {
        let state_clone = state.clone();
        handles.push(tokio::spawn(async move {
            let client = state_clone.sui_client().await.expect("Should succeed");
            client.id
        }));
    }

    // Wait for all tasks to complete
    let results: Vec<u64> = futures::future::join_all(handles)
        .await
        .into_iter()
        .map(|r| r.expect("Task should not panic"))
        .collect();

    // All tasks should get the same client ID
    let first_id = results[0];
    for id in &results {
        assert_eq!(
            *id, first_id,
            "All concurrent requests should use the same client"
        );
    }

    // Initialization should only happen once despite concurrent access
    assert_eq!(
        state.get_init_count(),
        1,
        "Client should only be initialized once"
    );
}

#[tokio::test]
async fn test_client_initialization_error_handling() {
    let state = MockAppState::new("https://invalid-url.example.com");

    // First call should fail
    let result1 = state.sui_client_failing().await;
    assert!(result1.is_err());
    assert_eq!(result1.unwrap_err(), "Failed to connect to RPC");

    // Subsequent calls should also fail (OnceCell doesn't cache errors)
    let result2 = state.sui_client_failing().await;
    assert!(result2.is_err());

    // Note: OnceCell's get_or_try_init will retry on error,
    // so init_count may be > 1 for error cases
    assert!(state.get_init_count() >= 1);
}

#[tokio::test]
async fn test_rpc_url_stored_correctly() {
    let url = "https://fullnode.mainnet.sui.io:443";
    let state = MockAppState::new(url);

    assert_eq!(state.rpc_url.as_str(), url);
}

#[tokio::test]
async fn test_arc_oncecell_is_clone_safe() {
    let state1 = MockAppState::new("https://example.com");

    // Clone the Arc<OnceCell<...>>
    let client_cell_clone = state1.sui_client.clone();

    // Initialize through original
    let _client = state1.sui_client().await.expect("Should succeed");

    // The clone should see the initialized value
    assert!(client_cell_clone.get().is_some());
}

#[tokio::test]
async fn test_multiple_state_clones_share_client() {
    // Simulate what happens when AppState is cloned (as it implements Clone)
    let original = Arc::new(MockAppState::new("https://example.com"));

    // Create multiple "clones" by sharing the Arc
    let clone1 = original.clone();
    let clone2 = original.clone();

    // Initialize through clone1
    let client1 = clone1.sui_client().await.expect("Should succeed");
    let id1 = client1.id;

    // Access through clone2 should get the same client
    let client2 = clone2.sui_client().await.expect("Should succeed");
    let id2 = client2.id;

    // Access through original should also get the same client
    let client3 = original.sui_client().await.expect("Should succeed");
    let id3 = client3.id;

    assert_eq!(id1, id2);
    assert_eq!(id2, id3);

    // Only one initialization
    assert_eq!(original.get_init_count(), 1);
}

/// Test that simulates the actual usage pattern in the server handlers
#[tokio::test]
async fn test_handler_usage_pattern() {
    let state = Arc::new(MockAppState::new("https://example.com"));

    // Simulate multiple API handlers being called concurrently
    // (like status, orderbook, deep_supply endpoints)

    let state_status = state.clone();
    let status_task = tokio::spawn(async move {
        // Simulating status handler
        let client = state_status
            .sui_client()
            .await
            .expect("status: should get client");
        client.id
    });

    let state_orderbook = state.clone();
    let orderbook_task = tokio::spawn(async move {
        // Simulating orderbook handler
        let client = state_orderbook
            .sui_client()
            .await
            .expect("orderbook: should get client");
        client.id
    });

    let state_deep_supply = state.clone();
    let deep_supply_task = tokio::spawn(async move {
        // Simulating deep_supply handler
        let client = state_deep_supply
            .sui_client()
            .await
            .expect("deep_supply: should get client");
        client.id
    });

    let (status_id, orderbook_id, deep_supply_id) =
        tokio::join!(status_task, orderbook_task, deep_supply_task);

    let status_id = status_id.expect("status task panicked");
    let orderbook_id = orderbook_id.expect("orderbook task panicked");
    let deep_supply_id = deep_supply_id.expect("deep_supply task panicked");

    // All handlers should use the same client
    assert_eq!(status_id, orderbook_id);
    assert_eq!(orderbook_id, deep_supply_id);

    // Client should only be initialized once
    assert_eq!(state.get_init_count(), 1);
}
