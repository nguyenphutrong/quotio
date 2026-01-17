/**
 * Proxy module exports
 * @packageDocumentation
 */

export type {
	Message,
	ChatCompletionRequest,
	ClaudeMessageRequest,
	ProxyRequest,
	ModelRoute,
} from './types.js';

export {
	MessageSchema,
	ChatCompletionRequestSchema,
	ClaudeMessageRequestSchema,
	PROVIDER_MODELS,
	inferProviderFromModel,
} from './types.js';

export type {
	ProxyResponse,
	ProxyStreamChunk,
	DispatcherConfig,
} from './dispatcher.js';

export { ProxyDispatcher, DispatchError } from './dispatcher.js';

export type { FallbackContext } from './fallback.js';

export {
	EMPTY_FALLBACK_CONTEXT,
	hasFallback,
	hasMoreFallbacks,
	getCurrentEntry,
	nextFallbackContext,
	getCachedEntryId,
	setCachedEntryId,
	clearCachedEntryId,
	updateRouteState,
	getRouteState,
	getAllRouteStates,
	clearRouteState,
	clearAllRouteStates,
	createFallbackContext,
	shouldFallbackOnStatus,
	shouldFallbackOnBody,
	shouldTriggerFallback,
	replaceModelInPayload,
	extractModelFromPayload,
	handleFallbackSuccess,
	mapProviderToExecutor,
} from './fallback.js';
