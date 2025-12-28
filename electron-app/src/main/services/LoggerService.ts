// ============================================
// Quotio - Logger Service
// Secure logging with sensitive data masking
// ============================================

import * as fs from 'fs';
import * as path from 'path';
import { app } from 'electron';
import { maskSensitiveData } from '../../shared/utils/security';
import type { LogEntry } from '../../shared/types';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LoggerConfig {
  level: LogLevel;
  maxLogs: number;
  logToFile: boolean;
  logFilePath?: string;
}

const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

export class LoggerService {
  private static instance: LoggerService;
  private logs: LogEntry[] = [];
  private config: LoggerConfig;
  private fileStream?: fs.WriteStream;

  private constructor() {
    this.config = {
      level: process.env.NODE_ENV === 'development' ? 'debug' : 'info',
      maxLogs: 1000,
      logToFile: false,
    };
  }

  static getInstance(): LoggerService {
    if (!LoggerService.instance) {
      LoggerService.instance = new LoggerService();
    }
    return LoggerService.instance;
  }

  configure(config: Partial<LoggerConfig>): void {
    this.config = { ...this.config, ...config };

    if (this.config.logToFile && !this.fileStream) {
      this.initFileLogging();
    }
  }

  private initFileLogging(): void {
    const logsDir = path.join(app.getPath('userData'), 'logs');

    if (!fs.existsSync(logsDir)) {
      fs.mkdirSync(logsDir, { recursive: true });
    }

    const logFile = this.config.logFilePath || path.join(logsDir, `quotio-${new Date().toISOString().split('T')[0]}.log`);
    this.fileStream = fs.createWriteStream(logFile, { flags: 'a' });
  }

  private shouldLog(level: LogLevel): boolean {
    return LOG_LEVELS[level] >= LOG_LEVELS[this.config.level];
  }

  private formatMessage(level: LogLevel, message: string, data?: Record<string, unknown>): string {
    const timestamp = new Date().toISOString();
    let formattedData = '';

    if (data) {
      // Mask sensitive data
      const sanitizedData = this.sanitizeData(data);
      formattedData = ` ${JSON.stringify(sanitizedData)}`;
    }

    return `[${timestamp}] [${level.toUpperCase()}] ${message}${formattedData}`;
  }

  private sanitizeData(data: Record<string, unknown>): Record<string, unknown> {
    const sensitiveKeys = ['password', 'token', 'key', 'secret', 'auth', 'credential', 'apiKey', 'accessToken', 'refreshToken'];
    const sanitized: Record<string, unknown> = {};

    for (const [key, value] of Object.entries(data)) {
      const lowerKey = key.toLowerCase();
      const isSensitive = sensitiveKeys.some(sk => lowerKey.includes(sk));

      if (isSensitive && typeof value === 'string') {
        sanitized[key] = maskSensitiveData(value);
      } else if (typeof value === 'object' && value !== null) {
        sanitized[key] = this.sanitizeData(value as Record<string, unknown>);
      } else {
        sanitized[key] = value;
      }
    }

    return sanitized;
  }

  private addLog(level: LogLevel, message: string, data?: Record<string, unknown>): void {
    const entry: LogEntry = {
      timestamp: new Date(),
      level,
      source: 'main',
      message,
      data: data ? this.sanitizeData(data) : undefined,
    };

    this.logs.push(entry);

    // Trim logs if exceeding max
    if (this.logs.length > this.config.maxLogs) {
      this.logs = this.logs.slice(-this.config.maxLogs);
    }

    // Log to file if configured
    if (this.fileStream) {
      this.fileStream.write(this.formatMessage(level, message, data) + '\n');
    }
  }

  debug(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('debug')) {
      console.debug(this.formatMessage('debug', message, data));
      this.addLog('debug', message, data);
    }
  }

  info(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('info')) {
      console.info(this.formatMessage('info', message, data));
      this.addLog('info', message, data);
    }
  }

  warn(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('warn')) {
      console.warn(this.formatMessage('warn', message, data));
      this.addLog('warn', message, data);
    }
  }

  error(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('error')) {
      console.error(this.formatMessage('error', message, data));
      this.addLog('error', message, data);
    }
  }

  getLogs(level?: LogLevel, limit?: number): LogEntry[] {
    let filteredLogs = this.logs;

    if (level) {
      filteredLogs = filteredLogs.filter(log => log.level === level);
    }

    if (limit) {
      filteredLogs = filteredLogs.slice(-limit);
    }

    return filteredLogs;
  }

  clearLogs(): void {
    this.logs = [];
  }

  close(): void {
    if (this.fileStream) {
      this.fileStream.end();
      this.fileStream = undefined;
    }
  }
}
