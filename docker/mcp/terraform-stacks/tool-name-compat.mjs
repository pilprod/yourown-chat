export function normalizeLegacyToolCall(body, prefix, currentNames) {
  const name = body?.method === "tools/call" ? body.params?.name : undefined;
  if (!name || currentNames.has(name) || !name.startsWith(prefix)) {
    return body;
  }
  const candidate = name.slice(prefix.length);
  if (!currentNames.has(candidate)) {
    return body;
  }
  return {
    ...body,
    params: {
      ...body.params,
      name: candidate,
    },
  };
}
