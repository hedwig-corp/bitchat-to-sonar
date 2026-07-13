#[tokio::main]
async fn main() {
    if let Err(error) = coding_bot_server::run().await {
        eprintln!("github-coding-bot failed: {error:#}");
        std::process::exit(1);
    }
}
