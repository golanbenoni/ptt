use anyhow::{bail, Context, Result};
use futures_util::{SinkExt, StreamExt};
use std::{env, time::Duration};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::HeaderValue, Bytes, Message},
};

#[tokio::main]
async fn main() -> Result<()> {
    let endpoint =
        env::var("PTT_CALL_EVENTS_ENDPOINT").context("PTT_CALL_EVENTS_ENDPOINT is required")?;
    let access_token = env::var("PTT_ACCESS_TOKEN").context("PTT_ACCESS_TOKEN is required")?;
    let mut request = endpoint.into_client_request()?;
    request.headers_mut().insert(
        "authorization",
        HeaderValue::from_str(&format!("Bearer {access_token}"))?,
    );
    let (mut socket, _) = connect_async(request).await?;

    let proof = Bytes::from_static(b"ptt-call-events-keepalive");
    socket.send(Message::Ping(proof.clone())).await?;
    let pong = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Pong(value))) => return Ok(value),
                Some(Ok(Message::Close(_))) | None => bail!("call event socket closed before pong"),
                Some(Err(error)) => return Err(error.into()),
                Some(Ok(_)) => {}
            }
        }
    })
    .await
    .context("timed out waiting for call event pong")??;
    if pong != proof {
        bail!("call event pong did not preserve the ping payload");
    }

    socket
        .send(Message::Text("client-data-is-forbidden".into()))
        .await?;
    let closed = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Close(_))) | None => return Ok::<(), anyhow::Error>(()),
                Some(Err(error)) => return Err(error.into()),
                Some(Ok(_)) => {}
            }
        }
    })
    .await
    .context("timed out waiting for client-message rejection")?;
    closed?;
    println!("Authenticated call-event WebSocket ping/pong and server-only message direction: ok");
    Ok(())
}
