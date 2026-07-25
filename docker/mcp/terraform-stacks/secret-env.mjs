import { readFileSync } from "node:fs";

export function readSecretEnv(name, environment = process.env) {
  const file = environment[`${name}_FILE`];
  return file ? readFileSync(file, "utf8").trim() : environment[name];
}
