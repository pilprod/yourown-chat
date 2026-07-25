export function toolResult(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    // MCP requires structuredContent to be an object. HCP list endpoints
    // return arrays, so keep the original payload under a stable key.
    structuredContent: { result: payload },
  };
}
