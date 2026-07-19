//! A local HTTP CONNECT proxy. Knows nothing about Minecraft or the tunnel
//! wire format — it only asks the shared `Multiplexer` for a new stream to
//! the requested target and relays bytes over it. This is the only place
//! that understands "why" we're tunneling; everything below `tunnel::`
//! never sees an HTTP byte.

use std::sync::Arc;

use anyhow::{Context, Result, bail};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::proxy::relay;
use crate::tunnel::multiplex::Multiplexer;

pub async fn serve(listen_addr: &str, multiplexer: Arc<Multiplexer>) -> Result<()> {
    let listener = TcpListener::bind(listen_addr)
        .await
        .with_context(|| format!("failed to bind proxy listener on {listen_addr}"))?;

    println!("HTTP CONNECT proxy listening on {listen_addr}");

    loop {
        let (client_stream, peer) = listener.accept().await?;
        let multiplexer = Arc::clone(&multiplexer);
        tokio::spawn(async move {
            if let Err(e) = handle_connection(client_stream, &multiplexer).await {
                eprintln!("[proxy] {peer}: {e:#}");
            }
        });
    }
}

async fn handle_connection(mut client: TcpStream, multiplexer: &Multiplexer) -> Result<()> {
    let (host, port) = read_connect_target(&mut client).await?;

    let (sender, receiver) = multiplexer
        .open_stream(&format!("{host}:{port}"))
        .await
        .context("failed to open tunnel stream")?;
    println!("[proxy] CONNECT {host}:{port} (stream {})", sender.id());

    client
        .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        .await
        .context("failed to reply to CONNECT")?;

    relay(client, sender, receiver).await;
    Ok(())
}

/// Reads and parses `CONNECT host:port HTTP/1.1\r\n...headers...\r\n\r\n`.
/// We don't care about the headers, only where the blank line is.
async fn read_connect_target(client: &mut TcpStream) -> Result<(String, u16)> {
    let mut buf = Vec::with_capacity(512);
    let mut byte = [0u8; 1];

    loop {
        let n = client.read(&mut byte).await?;
        if n == 0 {
            bail!("client closed before sending a request");
        }
        buf.push(byte[0]);
        if buf.ends_with(b"\r\n\r\n") {
            break;
        }
        if buf.len() > 8192 {
            bail!("request line too long");
        }
    }

    let request = String::from_utf8_lossy(&buf);
    let first_line = request.lines().next().unwrap_or_default();
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or_default();

    if !method.eq_ignore_ascii_case("CONNECT") {
        bail!("only CONNECT is supported, got {method:?}");
    }

    let (host, port) = target
        .rsplit_once(':')
        .context("CONNECT target missing a port")?;
    let port: u16 = port.parse().context("CONNECT target has an invalid port")?;
    Ok((host.to_owned(), port))
}
