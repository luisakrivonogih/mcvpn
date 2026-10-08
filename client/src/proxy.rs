pub mod http;
pub mod socks5;
pub mod udp_forward;

use bytes::Bytes;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::tunnel::stream::{StreamReceiver, StreamSender};

/// Pumps bytes in both directions between a local TCP socket (the browser/
/// app side of either front-end proxy) and a tunnel stream until either side
/// is done, then closes just this stream — the underlying Minecraft
/// connection and every other active stream on it are untouched. Shared by
/// both `http` (CONNECT) and `socks5`, since once a stream is open neither
/// front end cares any more what protocol asked for it: it's just bytes.
pub async fn relay(client: TcpStream, sender: StreamSender, mut receiver: StreamReceiver) {
    let (mut client_read, mut client_write) = client.into_split();

    let upload = async {
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            let n = match client_read.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => n,
            };
            if sender.send(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                return;
            }
        }
    };

    let download = async {
        while let Some(payload) = receiver.recv().await {
            if client_write.write_all(&payload).await.is_err() {
                return;
            }
        }
    };

    tokio::select! {
        _ = upload => {}
        _ = download => {}
    }

    sender.close().await;
}
