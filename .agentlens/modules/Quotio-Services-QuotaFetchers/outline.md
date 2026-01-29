# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 1 large files in this module.

## Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift (592 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 62 | class | KiroQuotaFetcher | (internal) |
| 68 | fn | socialTokenEndpoint | (private) |
| 73 | fn | idcTokenEndpoint | (private) |
| 78 | fn | usageEndpoint | (private) |
| 87 | method | init | (internal) |
| 94 | fn | updateProxyConfiguration | (internal) |
| 100 | fn | fetchAllQuotas | (internal) |
| 133 | fn | refreshAllTokensIfNeeded | (internal) |
| 160 | fn | shouldRefreshToken | (private) |
| 194 | fn | fetchQuota | (private) |
| 232 | fn | parseExpiryDate | (private) |
| 248 | fn | fetchUsageAPI | (private) |
| 313 | fn | refreshTokenWithExpiry | (private) |
| 328 | fn | refreshSocialTokenWithExpiry | (private) |
| 377 | fn | refreshIdCTokenWithExpiry | (private) |
| 449 | fn | syncToKiroIDEAuthFile | (private) |
| 481 | fn | persistRefreshedToken | (private) |
| 514 | fn | convertToQuotaData | (private) |

