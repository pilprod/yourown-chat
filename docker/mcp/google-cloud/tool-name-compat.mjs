export function resolveLegacyToolName(name, prefix, currentNames) {
  if (currentNames.has(name) || !name.startsWith(prefix)) {
    return name;
  }
  const candidate = name.slice(prefix.length);
  return currentNames.has(candidate) ? candidate : name;
}
