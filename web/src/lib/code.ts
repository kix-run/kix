// Static syntax colouring for the code cards. A line is a list of tokens;
// a token is plain text or [text, kind].
export type TokenKind = 'fn' | 'str' | 'pkg' | 'num' | 'comment' | 'ref';
export type Token = string | [string, TokenKind];
export type Line = Token[];

export const tokenClass: Record<TokenKind, string> = {
  fn: 'text-t-blue',
  num: 'text-t-blue',
  ref: 'text-t-blue',
  str: 'text-t-green',
  pkg: 'text-t-yellow',
  comment: 'text-t-dim',
};
