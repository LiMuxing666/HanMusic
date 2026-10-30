export class ServiceError extends Error {
  constructor(code, retryAfter) {
    super(code);
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

export const HTTP_STATUS = Object.freeze({
  service_unavailable: 503,
  rate_limited: 429,
  daily_limit: 429,
  invalid_audio: 400,
  upstream_timeout: 504,
  upstream_failure: 502,
});
