/** Optional environment-specific APNs credentials. The base key remains the
 * sandbox key; operators with a legacy dual-environment key can omit these. */
interface __BaseEnv_Env {
  APNS_PRODUCTION_KEY_ID?: string;
  APNS_PRODUCTION_PRIVATE_KEY?: string;
}
