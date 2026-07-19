use tokio::net::TcpStream;
use tokio_util::codec::Framed;

use super::codec::MinecraftCodec;

/// A TCP connection framed as a stream of raw Minecraft packets.
pub type McFramed = Framed<TcpStream, MinecraftCodec>;

pub fn new(stream: TcpStream) -> McFramed {
    Framed::new(stream, MinecraftCodec::new())
}
