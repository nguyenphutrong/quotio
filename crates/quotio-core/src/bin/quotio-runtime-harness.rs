use std::env;

use quotio_core::{ManagedRuntime, RuntimeConfig};

fn main() {
    let mut args = env::args().skip(1);
    let Some(binary_path) = args.next() else {
        eprintln!("usage: quotio-runtime-harness <binary> [args...]");
        std::process::exit(2);
    };

    let mut config = RuntimeConfig::new(binary_path, "http://127.0.0.1:8386");
    config.args = args.collect();

    let mut runtime = ManagedRuntime::new(config);
    match runtime.start() {
        Ok(snapshot) => {
            println!("{}", snapshot.status.state);
            let _ = runtime.stop();
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
