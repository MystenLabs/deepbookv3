use sui_types::transaction::{TransactionData, TransactionDataAPI, TransactionExpiration};

// The checkpoint reader deserializes transaction.bcs into TransactionData before
// filtering Core events. An unrelated transaction must not stall every pipeline.
#[test]
fn decodes_testnet_validity_transaction_that_stalled_ingestion() {
    let bytes = include_bytes!("fixtures/testnet-validity-384489661.bcs");
    let transaction: TransactionData =
        bcs::from_bytes(bytes).expect("Testnet checkpoint 384489661 must remain decodable");

    assert_eq!(
        transaction.digest().to_string(),
        "FR9z9yLfmHEJBKRvRqsd6qoK4Ty6fXYFMj5EH3e5Ukk"
    );
    match transaction.expiration() {
        TransactionExpiration::Validity {
            min_epoch,
            max_epoch,
            allowed_proposers: Some(proposers),
            ..
        } => {
            assert_eq!(*min_epoch, Some(1225));
            assert_eq!(*max_epoch, Some(1226));
            assert_eq!(proposers.epoch, 1225);
            assert_eq!(
                proposers.proposers.iter().copied().collect::<Vec<_>>(),
                vec![12, 42, 106]
            );
        }
        other => panic!("expected Validity with allowed proposers, got {other:?}"),
    }
    assert_eq!(bcs::to_bytes(&transaction).unwrap(), bytes);
}
