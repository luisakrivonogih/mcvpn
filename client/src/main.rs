mod config;
mod crypto;
mod mc;
mod net;
mod proxy;
mod tunnel;

use std::sync::Arc;

use config::ClientConfig;
use tunnel::multiplex::Multiplexer;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = ClientConfig::load();

    println!(
        "mcvpn client: HTTP CONNECT on {}, SOCKS5 on {}, tunneling through {}:{}",
        config.proxy_listen, config.socks_listen, config.server_host, config.server_port
    );

    // Blocks until the first connection succeeds (retrying with backoff),
    // then keeps itself connected in the background for the rest of the
    // process's life -- see `Multiplexer::spawn`.
    let multiplexer = Arc::new(Multiplexer::spawn(config.clone()).await);

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
