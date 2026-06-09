import { readFileSync, writeFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../..',
);
const schemaPath = path.join(root, 'schema/contract.json');
const checkOnly = process.argv.includes('--check');

const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));

function normalizeLineEndings(content) {
  return content.replace(/\r\n/g, '\n');
}

function pascal(value) {
  return value
    .split(/[^a-zA-Z0-9]+/)
    .filter(Boolean)
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join('');
}

function snake(value) {
  return value
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/[^a-zA-Z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toLowerCase();
}

function tsType(type) {
  if (type.endsWith('[]')) {
    return `${tsType(type.slice(0, -2))}[]`;
  }
  if (type === 'boolean') {
    return 'boolean';
  }
  return type === 'number' ? 'number' : 'string';
}

function rustType(field) {
  if (field.type.endsWith('[]')) {
    const inner = rustType({
      ...field,
      type: field.type.slice(0, -2),
      optional: false,
    });
    const base = `Vec<${inner}>`;
    return field.optional ? `Option<${base}>` : base;
  }
  const base =
    field.type === 'number'
      ? 'u16'
      : field.type === 'boolean'
        ? 'bool'
        : 'String';
  return field.optional ? `Option<${base}>` : base;
}

function csharpType(field) {
  if (field.type.endsWith('[]')) {
    const inner = csharpType({
      ...field,
      type: field.type.slice(0, -2),
      optional: false,
    });
    const base = `IReadOnlyList<${inner}>`;
    return field.optional ? `${base}?` : base;
  }
  const base =
    field.type === 'number'
      ? 'int'
      : field.type === 'boolean'
        ? 'bool'
        : 'string';
  return field.optional ? `${base}?` : base;
}

function swiftType(field) {
  if (field.type.endsWith('[]')) {
    const inner = swiftType({
      ...field,
      type: field.type.slice(0, -2),
      optional: false,
    });
    const base = `[${inner}]`;
    return field.optional ? `${base}?` : base;
  }
  const base =
    field.type === 'number'
      ? 'Int'
      : field.type === 'boolean'
        ? 'Bool'
        : 'String';
  return field.optional ? `${base}?` : base;
}

function generatedHeader(comment) {
  return `${comment} Generated from schema/contract.json. Do not edit manually.\n`;
}

function renderTs() {
  const requestKinds = schema.requests
    .map((request) => `'${request.kind}'`)
    .join(' | ');
  const eventKinds = schema.events
    .map((event) => `'${event.kind}'`)
    .join(' | ');
  const models = schema.models
    .map((model) => {
      const fields = model.fields
        .map(
          (field) =>
            `  ${field.name}${field.optional ? '?' : ''}: ${tsType(field.type)};`,
        )
        .join('\n');
      return `export type ${model.name} = {\n${fields}\n};`;
    })
    .join('\n\n');

  return `${generatedHeader('//')}\nexport const contractVersion = ${schema.contractVersion} as const;\n\nexport type RequestKind = ${requestKinds};\n\nexport type EventKind = ${eventKinds};\n\n${models}\n`;
}

function renderRust() {
  const requestKinds = schema.requests
    .map((request) => `"${request.kind}"`)
    .join(', ');
  const eventKinds = schema.events.map((event) => `"${event.kind}"`).join(', ');
  const models = schema.models
    .map((model) => {
      const fields = model.fields
        .map((field) => `    pub ${snake(field.name)}: ${rustType(field)},`)
        .join('\n');
      return `#[derive(Clone, Debug, PartialEq, Eq)]\npub struct ${model.name} {\n${fields}\n}`;
    })
    .join('\n\n');

  return `${generatedHeader('//')}\npub const CONTRACT_VERSION: u16 = ${schema.contractVersion};\npub const REQUEST_KINDS: &[&str] = &[${requestKinds}];\npub const EVENT_KINDS: &[&str] = &[${eventKinds}];\n\n${models}\n`;
}

function renderSwift() {
  const requestCases = schema.requests
    .map((request) => `    case ${pascal(request.kind)} = "${request.kind}"`)
    .join('\n');
  const eventCases = schema.events
    .map((event) => `    case ${pascal(event.kind)} = "${event.kind}"`)
    .join('\n');
  const models = schema.models
    .map((model) => {
      const fields = model.fields
        .map((field) => `    public let ${field.name}: ${swiftType(field)}`)
        .join('\n');
      return `public struct ${model.name}: Codable, Sendable, Equatable {\n${fields}\n}`;
    })
    .join('\n\n');

  return `${generatedHeader('//')}\npublic let quotioContractVersion = ${schema.contractVersion}\n\npublic enum QuotioRequestKind: String, Sendable {\n${requestCases}\n}\n\npublic enum QuotioEventKind: String, Sendable {\n${eventCases}\n}\n\n${models}\n`;
}

function renderCsharp() {
  const requestCases = schema.requests
    .map((request) => `    ${pascal(request.kind)},`)
    .join('\n');
  const eventCases = schema.events
    .map((event) => `    ${pascal(event.kind)},`)
    .join('\n');
  const models = schema.models
    .map((model) => {
      const fields = model.fields
        .map(
          (field) =>
            `    public required ${csharpType(field)} ${pascal(field.name)} { get; init; }`,
        )
        .join('\n');
      return `public sealed record ${model.name}\n{\n${fields}\n}`;
    })
    .join('\n\n');

  return `${generatedHeader('//')}\nnamespace Quotio.Contract;\n\npublic static class QuotioContract\n{\n    public const int Version = ${schema.contractVersion};\n}\n\npublic enum QuotioRequestKind\n{\n${requestCases}\n}\n\npublic enum QuotioEventKind\n{\n${eventCases}\n}\n\n${models}\n`;
}

const outputs = [
  ['packages/desktop-contract/src/generated.ts', renderTs()],
  ['crates/quotio-contract/src/generated.rs', renderRust()],
  ['generated/swift/QuotioContractGenerated.swift', renderSwift()],
  ['generated/csharp/Quotio.Contract/Generated.cs', renderCsharp()],
];

let stale = false;

for (const [relativePath, content] of outputs) {
  const outputPath = path.join(root, relativePath);
  if (checkOnly) {
    let current = '';
    try {
      current = normalizeLineEndings(readFileSync(outputPath, 'utf8'));
    } catch {
      stale = true;
      console.error(`${relativePath} is missing`);
      continue;
    }
    if (current !== content) {
      stale = true;
      console.error(`${relativePath} is stale`);
    }
    continue;
  }

  await mkdir(path.dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, content);
}

if (stale) {
  process.exitCode = 1;
}
