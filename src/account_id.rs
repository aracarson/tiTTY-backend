use sha2::{Digest, Sha256};

// MARK: - Task list
// [x] Derive the canonical AccountID from public-key bytes

pub fn from_public_key(public_key: &[u8]) -> String {
    let digest = Sha256::digest(public_key);
    format!("acct_{}", hex::encode(digest))
}
