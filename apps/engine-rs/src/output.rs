use std::io::{self, Write};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::sync::oneshot;

/// Bounded ingress for the Engine's single NDJSON stdout writer thread.
///
/// Durable output awaits capacity without blocking the current-thread Tokio
/// runtime. Ephemeral streaming deltas are deliberately best-effort so they
/// cannot crowd responses or persistent state notifications out of the queue.
#[derive(Clone)]
pub struct OutputWriter {
    sender: mpsc::Sender<OutputItem>,
}

enum OutputItem {
    Value(Value),
    Shutdown,
}

pub struct OutputReceiver {
    receiver: mpsc::Receiver<OutputItem>,
}

/// Completion signal for the dedicated blocking output thread.
///
/// The thread handle is deliberately detached. Waiting on a `JoinHandle` can
/// never be made safe when the operating-system write itself is stuck, while
/// dropping the handle lets the Engine process return and terminate that
/// thread after a bounded graceful-drain attempt.
pub struct OutputDrain {
    completion: oneshot::Receiver<io::Result<()>>,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DrainOutcome {
    Drained,
    TimedOut,
}

impl OutputWriter {
    pub fn channel(capacity: usize) -> (Self, OutputReceiver) {
        let (sender, receiver) = mpsc::channel(capacity);
        (Self { sender }, OutputReceiver { receiver })
    }

    pub async fn send<T: Serialize>(&self, value: &T) -> bool {
        let Ok(value) = serde_json::to_value(value) else {
            return false;
        };
        self.sender.send(OutputItem::Value(value)).await.is_ok()
    }

    pub fn try_send_ephemeral<T: Serialize>(&self, value: &T) -> bool {
        let Ok(value) = serde_json::to_value(value) else {
            return false;
        };
        self.sender.try_send(OutputItem::Value(value)).is_ok()
    }

    /// Best-effort output for parser/control-lane responses. Unlike `send`, it
    /// never waits for stdout capacity, so a wedged consumer cannot prevent the
    /// parser from reaching a later cancellation or shutdown request.
    pub fn try_send_control<T: Serialize>(&self, value: &T) -> bool {
        let Ok(value) = serde_json::to_value(value) else {
            return false;
        };
        self.sender.try_send(OutputItem::Value(value)).is_ok()
    }

    /// Ask the writer to stop after values already accepted by the queue.
    /// Failure only means the bounded queue is full; callers must still drop
    /// their senders and use `OutputDrain::wait` with a deadline.
    pub fn try_shutdown(&self) -> bool {
        self.sender.try_send(OutputItem::Shutdown).is_ok()
    }
}

impl OutputReceiver {
    pub fn blocking_recv(&mut self) -> Option<Value> {
        match self.receiver.blocking_recv()? {
            OutputItem::Value(value) => Some(value),
            OutputItem::Shutdown => None,
        }
    }

    #[cfg(test)]
    async fn recv(&mut self) -> Option<Value> {
        match self.receiver.recv().await? {
            OutputItem::Value(value) => Some(value),
            OutputItem::Shutdown => None,
        }
    }
}

/// Start the single ordered NDJSON writer on a blocking OS thread.
///
/// `sink` is generic so tests can deterministically model a permanently stuck
/// stdout write without depending on pipe-buffer sizes or scheduler timing.
pub fn spawn<W>(capacity: usize, mut sink: W) -> (OutputWriter, OutputDrain)
where
    W: Write + Send + 'static,
{
    let (writer, mut receiver) = OutputWriter::channel(capacity);
    let (completion_tx, completion) = oneshot::channel();
    std::thread::spawn(move || {
        let result = (|| -> io::Result<()> {
            while let Some(value) = receiver.blocking_recv() {
                let mut bytes = match serde_json::to_vec(&value) {
                    Ok(bytes) => bytes,
                    Err(_) => continue,
                };
                bytes.push(b'\n');
                sink.write_all(&bytes)?;
                sink.flush()?;
            }
            Ok(())
        })();
        let _ = completion_tx.send(result);
    });
    (writer, OutputDrain { completion })
}

impl OutputDrain {
    /// Wait at most `timeout` for already accepted output to drain. A timeout
    /// intentionally detaches the writer; returning from `main` then gives the
    /// process a hard upper bound even if the kernel write never comes back.
    pub async fn wait(self, timeout: Duration) -> io::Result<DrainOutcome> {
        match tokio::time::timeout(timeout, self.completion).await {
            Ok(Ok(result)) => result.map(|()| DrainOutcome::Drained),
            Ok(Err(_)) => Err(io::Error::other("stdout writer panicked")),
            Err(_) => Ok(DrainOutcome::TimedOut),
        }
    }
}

#[cfg(test)]
pub fn test_channel(capacity: usize) -> (OutputWriter, std::sync::mpsc::Receiver<Value>) {
    // Unit tests that inspect emitted values are not stdout-backpressure tests.
    // Keep their adapter effectively lossless and test bounded/drop semantics
    // directly against `OutputWriter::channel` below.
    let (writer, mut async_receiver) = OutputWriter::channel(capacity.max(1024 * 1024));
    // The Tokio queue is the system under test. A second bounded synchronous
    // queue would add unrelated scheduling loss when tests intentionally do
    // not drain until after producing a burst.
    let (test_sender, test_receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        while let Some(value) = async_receiver.blocking_recv() {
            if test_sender.send(value).is_err() {
                break;
            }
        }
    });
    (writer, test_receiver)
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc as std_mpsc;
    use std::time::Duration;

    use serde_json::json;

    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn durable_backpressure_yields_instead_of_blocking_the_runtime() {
        let (writer, mut receiver) = OutputWriter::channel(1);
        assert!(writer.try_send_ephemeral(&json!({"sequence": 1})));

        let pending_writer = writer.clone();
        let pending =
            tokio::spawn(async move { pending_writer.send(&json!({"sequence": 2})).await });
        tokio::task::yield_now().await;
        assert!(!pending.is_finished());

        tokio::time::timeout(Duration::from_millis(50), async {
            tokio::task::yield_now().await;
        })
        .await
        .expect("a full stdout queue must not block the current-thread runtime");

        assert_eq!(receiver.recv().await.unwrap()["sequence"], 1);
        assert!(pending.await.unwrap());
        assert_eq!(receiver.recv().await.unwrap()["sequence"], 2);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ephemeral_output_is_dropped_when_the_bounded_queue_is_full() {
        let (writer, mut receiver) = OutputWriter::channel(1);
        assert!(writer.try_send_ephemeral(&json!({"sequence": 1})));
        assert!(!writer.try_send_ephemeral(&json!({"sequence": 2})));
        assert_eq!(receiver.recv().await.unwrap()["sequence"], 1);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn control_output_never_waits_for_a_full_queue() {
        let (writer, mut receiver) = OutputWriter::channel(1);
        assert!(writer.try_send_control(&json!({"sequence": 1})));
        assert!(!writer.try_send_control(&json!({"sequence": 2})));
        assert_eq!(receiver.recv().await.unwrap()["sequence"], 1);
    }

    struct BlockingWriter {
        started: std_mpsc::SyncSender<()>,
        release: Option<std_mpsc::Receiver<()>>,
    }

    impl Write for BlockingWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let _ = self.started.send(());
            if let Some(release) = self.release.take() {
                let _ = release.recv();
            }
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn drain_deadline_survives_a_permanently_blocked_os_write_and_full_queue() {
        let (started_tx, started_rx) = std_mpsc::sync_channel(1);
        let (release_tx, release_rx) = std_mpsc::sync_channel(1);
        let (writer, drain) = spawn(
            1,
            BlockingWriter {
                started: started_tx,
                release: Some(release_rx),
            },
        );

        assert!(writer.try_send_control(&json!({"sequence": 1})));
        started_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("writer must enter the simulated OS write");
        assert!(writer.try_send_control(&json!({"sequence": 2})));
        assert!(
            !writer.try_shutdown(),
            "the output queue is intentionally full"
        );
        drop(writer);

        let started_at = tokio::time::Instant::now();
        assert_eq!(
            drain.wait(Duration::from_millis(25)).await.unwrap(),
            DrainOutcome::TimedOut
        );
        assert!(started_at.elapsed() < Duration::from_millis(250));

        // Let the detached test thread cleanly finish after proving that the
        // Engine-side deadline did not depend on the blocked writer returning.
        let _ = release_tx.send(());
    }
}
