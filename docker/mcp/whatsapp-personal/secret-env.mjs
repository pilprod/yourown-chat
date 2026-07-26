import { readFileSync } from "node:fs";

export function readSecretEnv(name, environment = process.env) {
  const file = environment[`${name}_FILE`];
  if (file) {
    return readFileSync(file, "utf8").trim();
  }
  return environment[name]?.trim();
}
