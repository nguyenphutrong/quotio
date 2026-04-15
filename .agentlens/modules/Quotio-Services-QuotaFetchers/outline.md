# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 1 large files in this module.

## Quotio/Services/QuotaFetchers/KiroQuotaFetcher.swift (677 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 64 | class | KiroQuotaFetcher | (internal) |
| 70 | fn | socialTokenEndpoint | (private) |
| 75 | fn | idcTokenEndpoint | (private) |
| 80 | fn | usageEndpoint | (private) |
| 85 | fn | extractRegionFromProfileArn | (private) |
| 99 | fn | machineId | (private) |
| 132 | fn | kiroUserAgent | (private) |
| 137 | fn | kiroAmzUserAgent | (private) |
| 148 | method | init | (internal) |
| 155 | fn | updateProxyConfiguration | (internal) |
| 161 | fn | fetchAllQuotas | (internal) |
| 194 | fn | refreshAllTokensIfNeeded | (internal) |
| 221 | fn | shouldRefreshToken | (private) |
| 255 | fn | fetchQuota | (private) |
| 293 | fn | parseExpiryDate | (private) |
| 309 | fn | fetchUsageAPI | (private) |
| 397 | fn | refreshTokenWithExpiry | (private) |
| 413 | fn | refreshSocialTokenWithExpiry | (private) |
| 462 | fn | refreshIdCTokenWithExpiry | (private) |
| 534 | fn | syncToKiroIDEAuthFile | (private) |
| 566 | fn | persistRefreshedToken | (private) |
| 599 | fn | convertToQuotaData | (private) |

