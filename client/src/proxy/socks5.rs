//! A local SOCKS5 proxy (RFC 1928), no-auth only, `CONNECT` command only.
//!
//! The HTTP CONNECT proxy in `proxy::http` already tunnels arbitrary bytes
//! once a stream is open — but plenty of software (torrent clients, chat
//! apps, games, `curl --socks5`, browsers configured for "SOCKS" instead of
//! "HTTP" proxying) never speaks HTTP CONNECT at all, and some only send
//! HTTP CONNECT for TLS targets while falling back to plain absolute-URI
//! requests for unencrypted HTTP. SOCKS5 is the one proxy protocol nearly
//! everything that wants to tunnel arbitrary TCP already knows how to
//! speak, so this is the actual "any traffic, not just HTTP" front door.
//! Like `http`, this knows nothing about Minecraft/tunnel internals — it
//! only asks the shared `Multiplexer` for a stream and relays bytes.

use std::net::Ipv4Addr;
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::proxy::relay;
use crate::tunnel::multiplex::Multiplexer;

const VERSION: u8 = 0x05;
const METHOD_NO_AUTH: u8 = 0x00;
const METHOD_NONE_ACCEPTABLE: u8 = 0xff;
const CMD_CONNECT: u8 = 0x01;
const ATYP_IPV4: u8 = 0x01;
const ATYP_DOMAIN: u8 = 0x03;
const ATYP_IPV6: u8 = 0x04;
const REP_SUCCEEDED: u8 = 0x00;
const REP_GENERAL_FAILURE: u8 = 0x01;
const REP_COMMAND_NOT_SUPPORTED: u8 = 0x07;

pub async fn serve(listen_addr: &str, multiplexer: Arc<Multiplexer>) -> Result<()> {
    let listener = TcpListener::bind(listen_addr)
        .await
        .with_context(|| format!("failed to bind socks5 listener on {listen_addr}"))?;

    println!("SOCKS5 proxy listening on {listen_addr}");

    loop {
        let (client_stream, peer) = listener.accept().await?;
        let multiplexer = Arc::clone(&multiplexer);
        tokio::spawn(async move {
            if let Err(e) = handle_connection(client_stream, &multiplexer).await {
                eprintln!("[socks5] {peer}: {e:#}");
            }
        });
    }
}

async fn handle_connection(mut client: TcpStream, multiplexer: &Multiplexer) -> Result<()> {
    negotiate_method(&mut client).await?;
    let (host, port) = read_connect_request(&mut client).await?;

    let stream = multiplexer.open_stream(&format!("{host}:{port}")).await;
    let (sender, receiver) = match stream {
        Ok(pair) => pair,
        Err(e) => {
            write_reply(&mut client, REP_GENERAL_FAILURE).await?;
            return Err(e).context("failed to open tunnel stream");
        }
    };
    println!("[socks5] CONNECT {host}:{port} (stream {})", sender.id());

    write_reply(&mut client, REP_SUCCEEDED).await?;
    relay(client, sender, receiver).await;
    Ok(())
}

/// Reads the greeting (`VER NMETHODS METHODS...`) and replies choosing
/// no-auth, the only method this proxy supports (it's already
/// authenticated/encrypted end-to-end by the tunnel itself, so an extra
/// SOCKS-level auth layer to a purely local listener buys nothing).
async fn negotiate_method(client: &mut TcpStream) -> Result<()> {
    let mut header = [0u8; 2];
    client.read_exact(&mut header).await?;
    let [version, nmethods] = header;
    if version != VERSION {
        bail!("unsupported SOCKS version {version:#x}");
    }

    let mut methods = vec![0u8; nmethods as usize];
    client.read_exact(&mut methods).await?;

    if !methods.contains(&METHOD_NO_AUTH) {
        client.write_all(&[VERSION, METHOD_NONE_ACCEPTABLE]).await?;
        bail!("client did not offer the no-auth method");
    }

    client.write_all(&[VERSION, METHOD_NO_AUTH]).await?;
    Ok(())
}

/// Reads `VER CMD RSV ATYP DST.ADDR DST.PORT` and returns `(host, port)` for
/// a `CONNECT` request. Only `CONNECT` is supported (no `BIND`/`UDP
/// ASSOCIATE`) since that's all a byte-relaying tunnel can offer.
async fn read_connect_request(client: &mut TcpStream) -> Result<(String, u16)> {
    let mut header = [0u8; 4];
    client.read_exact(&mut header).await?;
    let [version, cmd, _rsv, atyp] = header;
    if version != VERSION {
        bail!("unsupported SOCKS version {version:#x}");
    }
    if cmd != CMD_CONNECT {
        write_reply(client, REP_COMMAND_NOT_SUPPORTED).await?;
        bail!("unsupported SOCKS command {cmd:#x} (only CONNECT is implemented)");
    }

    let host = match atyp {
        ATYP_IPV4 => {
            let mut addr = [0u8; 4];
            client.read_exact(&mut addr).await?;
            Ipv4Addr::from(addr).to_string()
        }
        ATYP_DOMAIN => {
            let mut len = [0u8; 1];
            client.read_exact(&mut len).await?;
            let mut name = vec![0u8; len[0] as usize];
            client.read_exact(&mut name).await?;
            String::from_utf8(name).context("SOCKS domain name is not valid UTF-8")?
        }
        ATYP_IPV6 => {
            let mut addr = [0u8; 16];
            client.read_exact(&mut addr).await?;
            std::net::Ipv6Addr::from(addr).to_string()
        }
        other => bail!("unsupported SOCKS address type {other:#x}"),
    };

    let mut port_bytes = [0u8; 2];
    client.read_exact(&mut port_bytes).await?;
    let port = u16::from_be_bytes(port_bytes);

    Ok((host, port))
}

/// Writes a reply with the given status and a dummy `0.0.0.0:0` bind
/// address -- correct per RFC 1928 when the proxy has no meaningful local
/// bind address of its own to report, and ignored by every client that
/// matters here since they only care about `REP`.
async fn write_reply(client: &mut TcpStream, rep: u8) -> Result<()> {
    let reply = [VERSION, rep, 0x00, ATYP_IPV4, 0, 0, 0, 0, 0, 0];
    client.write_all(&reply).await?;
    Ok(())
}
