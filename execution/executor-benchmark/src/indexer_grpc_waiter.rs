// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use aptos_db_indexer::db_v2::IndexerAsyncV2;
use aptos_logger::info;
use aptos_types::transaction::Version;
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

const INDEXER_GRPC_POLL_INTERVAL_MS: u64 = 50;
const STATUS_LOG_INTERVAL_SECS: u64 = 1;

pub struct IndexerGrpcWaiter {
    indexer_table_info: Arc<IndexerAsyncV2>,
    stream_version: Arc<AtomicU64>,
}

impl IndexerGrpcWaiter {
    pub fn new(indexer_table_info: Arc<IndexerAsyncV2>, stream_version: Arc<AtomicU64>) -> Self {
        Self {
            indexer_table_info,
            stream_version,
        }
    }

    pub async fn wait_for_version(&self, target_version: Version) {
        info!(
            "Waiting for indexer_grpc to reach target version: {}",
            target_version
        );

        let start_time = Instant::now();
        let mut last_log_time = Instant::now();

        loop {
            let table_info_version = self.indexer_table_info.next_version().saturating_sub(1);
            let stream_version = self.stream_version.load(Ordering::SeqCst);
            if stream_version >= target_version {
                info!(
                    "Indexer stream reached target version. Current: {}, Target: {}, elapsed: {:.2}s",
                    stream_version,
                    target_version,
                    start_time.elapsed().as_secs_f64()
                );
                break;
            }

            // Log status every 1 second
            if last_log_time.elapsed().as_secs() >= STATUS_LOG_INTERVAL_SECS {
                let versions_behind = target_version.saturating_sub(stream_version);
                let elapsed_secs = start_time.elapsed().as_secs_f64();
                info!(
                    "Indexer_grpc progress: target={}, table_info_current={}, stream_version={}, behind={}, elapsed={:.2}s",
                    target_version, table_info_version, stream_version, versions_behind, elapsed_secs
                );
                last_log_time = Instant::now();
            }

            tokio::time::sleep(Duration::from_millis(INDEXER_GRPC_POLL_INTERVAL_MS)).await;
        }
    }
}
