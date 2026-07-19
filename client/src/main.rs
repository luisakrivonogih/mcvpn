mod config;
mod crypto;
mod mc;
mod net;
mod proxy;
mod tunnel;

use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use config::ClientConfig;
use mc::session::Session;
use tunnel::multiplex::Multiplexer;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = ClientConfig::load();

    println!(
        "mcvpn client: HTTP CONNECT on {}, SOCKS5 on {}, tunneling through {}:{}",
        config.proxy_listen, config.socks_listen, config.server_host, config.server_port
    );

    let multiplexer = Arc::new(connect_with_retry(&config).await);

    // Two front doors onto the same tunnel: HTTP CONNECT for proxy-aware
    // apps that expect one, SOCKS5 for everything else (see
    // `proxy::socks5` for why one alone isn't "any traffic"). Either
    // listener failing to even bind is fatal; a single connection failing
    // inside either is handled per-connection and never brings the process
    // down.
    tokio::try_join!(
        proxy::http::serve(&config.proxy_listen, Arc::clone(&multiplexer)),
        proxy::socks5::serve(&config.socks_listen, multiplexer),
    )?;
    Ok(())
}

/// Establishes the one persistent Minecraft connection the multiplexer runs
/// over (including its handshake), retrying with backoff so a transient
/// network hiccup doesn't require restarting the whole client before the
/// first browser request.
///
/// Known limitation: this only covers the *initial* connect. If the
/// Minecraft connection dies later (server restart, network drop), every
/// open stream ends and new `open_stream` calls will fail — the client
/// needs restarting. Live reconnect-and-resume is a reasonable next step,
/// not implemented here.
async fn connect_with_retry(config: &ClientConfig) -> Multiplexer {
    let mut backoff = Duration::from_secs(1);
    loop {
        match connect_once(config).await {
            Ok(multiplexer) => return multiplexer,
            Err(e) => {
                eprintln!("failed to connect: {e:#}; retrying in {backoff:?}");
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
    }
}

async fn connect_once(config: &ClientConfig) -> Result<Multiplexer> {
    let session = Session::connect(config).await?;
    println!(
        "minecraft transport established: uuid={} username={} entity_id={}",
        session.uuid, session.username, session.entity_id
    );

    let multiplexer = Multiplexer::spawn(session.spawn(), config.key_id, config.key_secret.clone()).await?;
    println!("tunnel handshake complete");
    Ok(multiplexer)
}
