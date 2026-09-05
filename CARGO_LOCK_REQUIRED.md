# Cargo.lock

Run `cargo generate-lockfile` and commit `Cargo.lock` before production deployment. The deployment script uses `cargo build --release --locked` intentionally.
