export function toolResult(value) {
  const text = JSON.stringify(value, null, 2);
  return {
    content: [{ type: "text", text }],
    structuredContent: value,
  };
}

export function toolError(error) {
  return {
    content: [
      {
        type: "text",
        text: error instanceof Error ? error.message : String(error),
      },
    ],
    isError: true,
  };
}
