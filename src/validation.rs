use crate::error::ApiError;

// MARK: - Task list
// [x] Match the client-side identiTTY normalisation rules
// [x] Keep identifiers ASCII-only to avoid Unicode confusables in v1

pub fn normalise_identitty(value: &str) -> Result<String, ApiError> {
    let value = value.trim().to_ascii_lowercase();
    let length = value.len();

    if !(3..=32).contains(&length) {
        return Err(ApiError::InvalidIdentitty);
    }

    let mut chars = value.chars();
    if !chars
        .next()
        .is_some_and(|character| character.is_ascii_lowercase())
    {
        return Err(ApiError::InvalidIdentitty);
    }

    if !value.chars().all(|character| {
        character.is_ascii_lowercase()
            || character.is_ascii_digit()
            || character == '_'
            || character == '-'
    }) {
        return Err(ApiError::InvalidIdentitty);
    }

    Ok(value)
}
