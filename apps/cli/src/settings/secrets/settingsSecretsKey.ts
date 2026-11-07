import { deriveSettingsSecretsKeySetV1 } from '@happier-dev/protocol';

import { resolveAccountScopedCryptoMaterial, type Credentials } from '@/persistence';

export function deriveSettingsSecretsKeyForCredentials(credentials: Credentials): Uint8Array {
  return deriveSettingsSecretsKeySetV1(resolveAccountScopedCryptoMaterial(credentials)).writeKey;
}

export function deriveSettingsSecretsReadKeysForCredentials(credentials: Credentials): readonly Uint8Array[] {
  return deriveSettingsSecretsKeySetV1(resolveAccountScopedCryptoMaterial(credentials)).readKeys;
}
