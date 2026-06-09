export class AdminBootstrapError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AdminBootstrapError';
  }
}

export class AdminAuthError extends Error {
  constructor(message = 'Unauthorized') {
    super(message);
    this.name = 'AdminAuthError';
  }
}

export class AdminApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = 'AdminApiError';
    this.status = status;
  }
}
