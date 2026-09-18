export function searchRequest(selectedText: string): string | undefined {
  const query = selectedText.trim();
  if (!query) return undefined;
  // encodeURIComponent uses %20 for spaces. URLSearchParams would use +,
  // which Foundation URLComponents correctly preserves as a literal plus.
  return `linklet://search?text=${encodeURIComponent(query)}`;
}
