import assert from "node:assert/strict";
import { test } from "node:test";
import { searchRequest } from "../src/search-request.ts";

test("selection survives URL transport without changing punctuation or Unicode", () => {
  const text = "C++ / café & Привет #100%?\nвторая строка";
  const request = searchRequest(`  ${text}  `)!;
  assert.equal(new URL(request).searchParams.get("text"), text);
  assert.ok(request.includes("%2B%2B"));
  assert.ok(request.includes("%20"));
  assert.ok(!request.includes("+"));
});

test("empty selection never opens a stale clipboard search", () => {
  assert.equal(searchRequest(""), undefined);
  assert.equal(searchRequest(" \n\t"), undefined);
});

test("selected URLs are passed as text, never executed as commands", () => {
  for (const text of ["https://example.com", "file:///tmp/example", "javascript:alert(1)"]) {
    const request = new URL(searchRequest(text)!);
    assert.equal(request.protocol, "linklet:");
    assert.equal(request.hostname, "search");
    assert.equal(request.searchParams.get("text"), text);
  }
});
