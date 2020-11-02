use super::super::SysTimer;
use crate::{client::Client, metrics::PlayerMetrics, Settings};
use common::{
    event::{EventBus, ServerEvent},
    msg::PingMsg,
    span,
    state::Time,
};
use specs::{Entities, Join, Read, ReadExpect, ReadStorage, System, Write};
use std::sync::atomic::Ordering;
use tracing::{debug, info};

impl Sys {
    fn handle_ping_msg(client: &Client, msg: PingMsg) -> Result<(), crate::error::Error> {
        match msg {
            PingMsg::Ping => client.send(PingMsg::Pong)?,
            PingMsg::Pong => {},
        }
        Ok(())
    }
}

/// This system will handle new messages from clients
pub struct Sys;
impl<'a> System<'a> for Sys {
    #[allow(clippy::type_complexity)]
    type SystemData = (
        Entities<'a>,
        Read<'a, EventBus<ServerEvent>>,
        Read<'a, Time>,
        ReadExpect<'a, PlayerMetrics>,
        Write<'a, SysTimer<Self>>,
        ReadStorage<'a, Client>,
        Read<'a, Settings>,
    );

    fn run(
        &mut self,
        (
            entities,
            server_event_bus,
            time,
            player_metrics,
            mut timer,
            clients,
            settings,
        ): Self::SystemData,
    ) {
        span!(_guard, "run", "msg::ping::Sys::run");
        timer.start();

        let mut server_emitter = server_event_bus.emitter();

        for (entity, client) in (&entities, &clients).join() {
            let res = super::try_recv_all(client, 4, Self::handle_ping_msg);

            match res {
                Err(e) => {
                    if !client.terminate_msg_recv.load(Ordering::Relaxed) {
                        debug!(?entity, ?e, "network error with client, disconnecting");
                        player_metrics
                            .clients_disconnected
                            .with_label_values(&["network_error"])
                            .inc();
                        server_emitter.emit(ServerEvent::ClientDisconnect(entity));
                    }
                },
                Ok(1_u64..=u64::MAX) => {
                    // Update client ping.
                    *client.last_ping.lock().unwrap() = time.0
                },
                Ok(0) => {
                    let last_ping: f64 = *client.last_ping.lock().unwrap();
                    if time.0 - last_ping > settings.client_timeout.as_secs() as f64
                    // Timeout
                    {
                        if !client.terminate_msg_recv.load(Ordering::Relaxed) {
                            info!(?entity, "timeout error with client, disconnecting");
                            player_metrics
                                .clients_disconnected
                                .with_label_values(&["timeout"])
                                .inc();
                            server_emitter.emit(ServerEvent::ClientDisconnect(entity));
                        }
                    } else if time.0 - last_ping > settings.client_timeout.as_secs() as f64 * 0.5 {
                        // Try pinging the client if the timeout is nearing.
                        client.send_fallible(PingMsg::Ping);
                    }
                },
            }
        }

        timer.end()
    }
}
