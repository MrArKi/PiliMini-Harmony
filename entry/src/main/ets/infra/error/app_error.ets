/**
 * 统一错误模型（spec-01 任务 1.5）
 */
export type AppErrorType = 'network' | 'auth' | 'biz' | 'parse' | 'unknown';

export class AppError extends Error {
  type: AppErrorType;
  code: number;

  constructor(type: AppErrorType, code: number, message: string) {
    super(message);
    this.type = type;
    this.code = code;
    this.name = 'AppError';
  }
}
