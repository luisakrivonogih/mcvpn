use std::io;

use tokio::net::TcpStream;
use tokio::net::ToSocketAddrs;

/// Opens a TCP connection to a Minecraft server.
///
/// `addr` accepts anything `tokio::net::TcpStream::connect` does (a
/// `"host:port"` string, a `SocketAddr`, etc.), so DNS resolution is handled
/// by the standard resolver rather than reimplemented here.
pub async fn connect(addr: impl ToSocketAddrs) -> io::Result<TcpStream> {
    let stream = TcpStream::connect(addr).await?;
    // Minecraft's protocol is latency-sensitive and packet-framed at the
    // application layer already; Nagle's algorithm only adds delay here.
    stream.set_nodelay(true)?;
    Ok(stream)
}
