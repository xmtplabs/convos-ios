const REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{20,100}$/;
const RETURN_TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,200}$/;

export function isValidRequestId(value: string): boolean {
  return REQUEST_ID_PATTERN.test(value);
}

export function isValidReturnToken(value: string): boolean {
  return RETURN_TOKEN_PATTERN.test(value);
}

export function constantTimeEqual(left: string, right: string): boolean {
  const maximumLength = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;

  for (let index = 0; index < maximumLength; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}
