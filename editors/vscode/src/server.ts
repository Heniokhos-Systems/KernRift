import {
    createConnection, TextDocuments, ProposedFeatures,
    InitializeParams, InitializeResult, TextDocumentSyncKind,
    CompletionItem, CompletionItemKind, Hover, MarkupKind,
    Diagnostic, DiagnosticSeverity, DefinitionParams, Location,
    Range, Position
} from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';
import { execSync } from 'child_process';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';

const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

let krcPath = 'krc';
// Per-server counter so concurrent validations don't collide on one temp file.
let tmpSeq = 0;

// --- Keywords and builtins ---

const KEYWORDS = [
    'fn', 'let', 'struct', 'enum', 'static', 'const', 'type', 'unsafe', 'volatile',
    'asm', 'import', 'device', 'at',
    'if', 'else', 'while', 'for', 'in', 'break', 'continue', 'loop', 'defer',
    'return', 'match', 'true', 'false', 'extern', 'export'
];

const TYPES = [
    // Long forms
    'uint8', 'uint16', 'uint32', 'uint64',
    'int8', 'int16', 'int32', 'int64',
    // Short aliases
    'u8', 'u16', 'u32', 'u64',
    'i8', 'i16', 'i32', 'i64',
    // Floating point
    'f16', 'f32', 'f64'
];

const BUILTINS: Record<string, { sig: string, doc: string }> = {
    // Core I/O
    'exit': { sig: 'fn exit(code: u64)', doc: 'Terminate the process with the given exit code.' },
    'print': { sig: 'fn print(arg)', doc: 'Print a string literal or format an integer to stdout (no newline).' },
    'println': { sig: 'fn println(arg)', doc: 'Print a string literal or integer followed by a newline.' },
    'print_str': { sig: 'fn print_str(s: u64)', doc: 'Print a null-terminated string from a pointer variable.' },
    'println_str': { sig: 'fn println_str(s: u64)', doc: 'Print a null-terminated string followed by a newline.' },
    'write': { sig: 'fn write(fd: u64, buf: u64, len: u64)', doc: 'Write `len` bytes from `buf` to file descriptor `fd`.' },

    // Files
    'file_open': { sig: 'fn file_open(path: u64, flags: u64) -> u64', doc: 'Open a file. flags: 0=read, 1=write. Returns file descriptor.' },
    'file_read': { sig: 'fn file_read(fd: u64, buf: u64, len: u64)', doc: 'Read `len` bytes from `fd` into `buf`.' },
    'file_write': { sig: 'fn file_write(fd: u64, buf: u64, len: u64)', doc: 'Write `len` bytes from `buf` to `fd`.' },
    'file_close': { sig: 'fn file_close(fd: u64)', doc: 'Close a file descriptor.' },
    'file_size': { sig: 'fn file_size(fd: u64) -> u64', doc: 'Return the size of the file in bytes.' },

    // Memory
    'alloc': { sig: 'fn alloc(size: u64) -> u64', doc: 'Allocate `size` bytes of memory. Returns pointer.' },
    'dealloc': { sig: 'fn dealloc(ptr: u64)', doc: 'Free previously allocated memory.' },
    'memcpy': { sig: 'fn memcpy(dst: u64, src: u64, len: u64)', doc: 'Copy `len` bytes from `src` to `dst`.' },
    'memset': { sig: 'fn memset(dst: u64, val: u64, len: u64)', doc: 'Fill `len` bytes at `dst` with `val`.' },
    'str_len': { sig: 'fn str_len(s: u64) -> u64', doc: 'Return the length of a null-terminated string.' },
    'str_eq': { sig: 'fn str_eq(a: u64, b: u64) -> u64', doc: 'Compare two strings. Returns 1 if equal, 0 if not.' },

    // Pointer load/store (v2.6)
    'load8':  { sig: 'fn load8(addr: u64) -> u64',  doc: 'Read a byte from memory at `addr`, zero-extended to u64.' },
    'load16': { sig: 'fn load16(addr: u64) -> u64', doc: 'Read a 16-bit word from memory at `addr`, zero-extended.' },
    'load32': { sig: 'fn load32(addr: u64) -> u64', doc: 'Read a 32-bit word from memory at `addr`, zero-extended.' },
    'load64': { sig: 'fn load64(addr: u64) -> u64', doc: 'Read a 64-bit word from memory at `addr`.' },
    'store8':  { sig: 'fn store8(addr: u64, val: u64)',  doc: 'Write a byte to memory at `addr`.' },
    'store16': { sig: 'fn store16(addr: u64, val: u64)', doc: 'Write a 16-bit word to memory at `addr`.' },
    'store32': { sig: 'fn store32(addr: u64, val: u64)', doc: 'Write a 32-bit word to memory at `addr`.' },
    'store64': { sig: 'fn store64(addr: u64, val: u64)', doc: 'Write a 64-bit word to memory at `addr`.' },

    // Volatile (for MMIO)
    'vload8':  { sig: 'fn vload8(addr: u64) -> u64',  doc: 'Volatile byte load with memory barrier (for MMIO).' },
    'vload16': { sig: 'fn vload16(addr: u64) -> u64', doc: 'Volatile 16-bit load with memory barrier.' },
    'vload32': { sig: 'fn vload32(addr: u64) -> u64', doc: 'Volatile 32-bit load with memory barrier.' },
    'vload64': { sig: 'fn vload64(addr: u64) -> u64', doc: 'Volatile 64-bit load with memory barrier.' },
    'vstore8':  { sig: 'fn vstore8(addr: u64, val: u64)',  doc: 'Volatile byte store with memory barrier.' },
    'vstore16': { sig: 'fn vstore16(addr: u64, val: u64)', doc: 'Volatile 16-bit store with memory barrier.' },
    'vstore32': { sig: 'fn vstore32(addr: u64, val: u64)', doc: 'Volatile 32-bit store with memory barrier.' },
    'vstore64': { sig: 'fn vstore64(addr: u64, val: u64)', doc: 'Volatile 64-bit store with memory barrier.' },

    // Atomic
    'atomic_load':  { sig: 'fn atomic_load(ptr: u64) -> u64', doc: 'Sequentially-consistent atomic load.' },
    'atomic_store': { sig: 'fn atomic_store(ptr: u64, val: u64)', doc: 'Sequentially-consistent atomic store.' },
    'atomic_cas':   { sig: 'fn atomic_cas(ptr: u64, exp: u64, des: u64) -> u64', doc: 'Compare-and-swap. Returns 1 on success, 0 on failure.' },
    'atomic_add':   { sig: 'fn atomic_add(ptr: u64, val: u64) -> u64', doc: 'Atomically add. Returns old value.' },
    'atomic_sub':   { sig: 'fn atomic_sub(ptr: u64, val: u64) -> u64', doc: 'Atomically subtract. Returns old value.' },
    'atomic_and':   { sig: 'fn atomic_and(ptr: u64, val: u64) -> u64', doc: 'Atomically AND. Returns old value.' },
    'atomic_or':    { sig: 'fn atomic_or(ptr: u64, val: u64) -> u64', doc: 'Atomically OR. Returns old value.' },
    'atomic_xor':   { sig: 'fn atomic_xor(ptr: u64, val: u64) -> u64', doc: 'Atomically XOR. Returns old value.' },

    // Bitfield
    'bit_get':    { sig: 'fn bit_get(v: u64, n: u64) -> u64', doc: 'Return bit `n` of `v` (0 or 1).' },
    'bit_set':    { sig: 'fn bit_set(v: u64, n: u64) -> u64', doc: 'Return `v` with bit `n` set.' },
    'bit_clear':  { sig: 'fn bit_clear(v: u64, n: u64) -> u64', doc: 'Return `v` with bit `n` cleared.' },
    'bit_range':  { sig: 'fn bit_range(v: u64, start: u64, width: u64) -> u64', doc: 'Extract `width` bits starting at `start`.' },
    'bit_insert': { sig: 'fn bit_insert(v: u64, start: u64, width: u64, bits: u64) -> u64', doc: 'Insert `bits` into `v` at position `start`.' },

    // Signed comparison
    'signed_lt': { sig: 'fn signed_lt(a: u64, b: u64) -> u64', doc: 'Signed less-than (default <, <=, >, >= are unsigned).' },
    'signed_gt': { sig: 'fn signed_gt(a: u64, b: u64) -> u64', doc: 'Signed greater-than.' },
    'signed_le': { sig: 'fn signed_le(a: u64, b: u64) -> u64', doc: 'Signed less-than-or-equal.' },
    'signed_ge': { sig: 'fn signed_ge(a: u64, b: u64) -> u64', doc: 'Signed greater-than-or-equal.' },

    // Platform / process
    'get_target_os':    { sig: 'fn get_target_os() -> u64', doc: 'Host OS: 0=Linux, 1=macOS, 2=Windows, 3=Android.' },
    'get_arch_id':      { sig: 'fn get_arch_id() -> u64', doc: 'Host architecture: 1=x86_64, 2=ARM64.' },
    'exec_process':     { sig: 'fn exec_process(path: u64) -> u64', doc: 'Execute a process at `path`. Returns exit code.' },
    'set_executable':   { sig: 'fn set_executable(path: u64)', doc: 'chmod +x equivalent.' },
    'get_module_path':  { sig: 'fn get_module_path(buf: u64, size: u64) -> u64', doc: "Write the current binary's path into `buf`." },
    'fmt_uint':         { sig: 'fn fmt_uint(buf: u64, val: u64) -> u64', doc: 'Format `val` as decimal into `buf`. Returns length.' },
    'syscall_raw':      { sig: 'fn syscall_raw(nr, a1, a2, a3, a4, a5, a6) -> u64', doc: 'Raw syscall with up to 6 arguments.' },

    // Function pointers
    'fn_addr':  { sig: 'fn fn_addr(name) -> u64', doc: 'Get the address of a named function.' },
    'call_ptr': { sig: 'fn call_ptr(addr, ...)', doc: 'Call a function by address with any number of arguments.' },
};

// --- Initialize ---

connection.onInitialize((params: InitializeParams): InitializeResult => {
    const config = params.initializationOptions;
    if (config?.compilerPath) krcPath = config.compilerPath;

    return {
        capabilities: {
            textDocumentSync: TextDocumentSyncKind.Full,
            completionProvider: { triggerCharacters: ['.', '@', '"'] },
            hoverProvider: true,
            definitionProvider: true,
        }
    };
});

// --- Diagnostics via krc check ---

// Parse krc's diagnostic output. Current krc format (v2.8.x) is:
//   <file>:<line>:<col>: error: <message>
//        3 |     return 0
//          |     ^~~~~~
//   1 parse error(s)
// so we match the header line and ignore the source/caret/summary lines.
const KRC_DIAG = /^.*?:(\d+):(\d+): (error|warning): (.+)$/gm;

function parseKrcDiagnostics(output: string, lines: string[]): Diagnostic[] {
    const diagnostics: Diagnostic[] = [];
    KRC_DIAG.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = KRC_DIAG.exec(output)) !== null) {
        const line = parseInt(match[1], 10) - 1;
        const col = Math.max(0, parseInt(match[2], 10) - 1);
        const severity = match[3] === 'warning'
            ? DiagnosticSeverity.Warning
            : DiagnosticSeverity.Error;
        const message = match[4];
        if (line < 0 || line >= lines.length) continue;
        diagnostics.push({
            severity,
            range: {
                start: { line, character: col },
                end: { line, character: lines[line]?.length || col + 1 }
            },
            message,
            source: 'krc'
        });
    }
    return diagnostics;
}

function validateDocument(doc: TextDocument): void {
    const text = doc.getText();
    const uri = doc.uri;
    const lines = text.split('\n');
    let diagnostics: Diagnostic[] = [];

    // Run `krc check` on a temp copy of the buffer. krc exits non-zero when it
    // finds problems, so execSync throws and the output arrives via e.stdout.
    const tmpFile = path.join(os.tmpdir(), `krc_lsp_${process.pid}_${tmpSeq++}.kr`);
    try {
        fs.writeFileSync(tmpFile, text);
        let output = '';
        try {
            output = execSync(`"${krcPath}" check "${tmpFile}" 2>&1`, {
                timeout: 5000,
                encoding: 'utf8'
            });
        } catch (e: any) {
            output = e.stdout || e.stderr || e.message || '';
        }
        diagnostics = parseKrcDiagnostics(output, lines);
    } catch {
        // krc missing / unrunnable: leave diagnostics empty rather than throw.
    } finally {
        try { fs.unlinkSync(tmpFile); } catch { /* already gone */ }
    }

    connection.sendDiagnostics({ uri, diagnostics });
}

documents.onDidChangeContent(change => {
    validateDocument(change.document);
});

documents.onDidSave(change => {
    validateDocument(change.document);
});

// --- Completions ---

connection.onCompletion((params): CompletionItem[] => {
    const doc = documents.get(params.textDocument.uri);
    if (!doc) return [];

    const text = doc.getText();
    const offset = doc.offsetAt(params.position);
    const lineText = text.substring(text.lastIndexOf('\n', offset - 1) + 1, offset);
    const items: CompletionItem[] = [];

    // After @: suggest annotations
    if (lineText.endsWith('@')) {
        ['export', 'ctx', 'eff', 'caps'].forEach((name, i) => {
            items.push({
                label: name,
                kind: CompletionItemKind.Keyword,
                detail: `@${name}`,
                sortText: String(i)
            });
        });
        return items;
    }

    // After import ": suggest std/ modules
    if (lineText.match(/import\s+"$/)) {
        ['std/string.kr', 'std/io.kr', 'std/math.kr', 'std/fmt.kr',
         'std/mem.kr', 'std/vec.kr', 'std/map.kr'].forEach((mod, i) => {
            items.push({
                label: mod,
                kind: CompletionItemKind.Module,
                insertText: mod,
                sortText: String(i)
            });
        });
        return items;
    }

    // After dot: suggest struct fields (basic — scan for struct definitions)
    if (lineText.endsWith('.')) {
        const word = lineText.slice(0, -1).match(/(\w+)$/)?.[1];
        if (word) {
            // Find struct type of this variable
            const varDecl = text.match(new RegExp(`(\\w+)\\s+${word}\\b`));
            if (varDecl) {
                const structName = varDecl[1];
                const structMatch = text.match(new RegExp(`struct\\s+${structName}\\s*\\{([^}]*)\\}`));
                if (structMatch) {
                    const fields = structMatch[1].match(/\w+\s+(\w+)/g);
                    fields?.forEach(f => {
                        const fieldName = f.split(/\s+/)[1];
                        if (fieldName) {
                            items.push({
                                label: fieldName,
                                kind: CompletionItemKind.Field
                            });
                        }
                    });
                }
            }
        }
        return items;
    }

    // General completions: keywords, types, builtins, functions in file
    KEYWORDS.forEach(kw => {
        items.push({ label: kw, kind: CompletionItemKind.Keyword });
    });

    TYPES.forEach(t => {
        items.push({ label: t, kind: CompletionItemKind.TypeParameter });
    });

    Object.keys(BUILTINS).forEach(name => {
        items.push({
            label: name,
            kind: CompletionItemKind.Function,
            detail: BUILTINS[name].sig,
            documentation: BUILTINS[name].doc
        });
    });

    // Functions defined in the file
    const fnRegex = /fn\s+(\w+)\s*\(/g;
    let match;
    while ((match = fnRegex.exec(text)) !== null) {
        const name = match[1];
        if (!BUILTINS[name] && name !== 'main') {
            items.push({
                label: name,
                kind: CompletionItemKind.Function,
                detail: `fn ${name}(...)`,
            });
        }
    }

    // Structs defined in the file
    const structRegex = /struct\s+(\w+)/g;
    while ((match = structRegex.exec(text)) !== null) {
        items.push({
            label: match[1],
            kind: CompletionItemKind.Struct,
        });
    }

    // Enums defined in the file
    const enumRegex = /enum\s+(\w+)/g;
    while ((match = enumRegex.exec(text)) !== null) {
        items.push({
            label: match[1],
            kind: CompletionItemKind.Enum,
        });
    }

    return items;
});

// --- Hover ---

connection.onHover((params): Hover | null => {
    const doc = documents.get(params.textDocument.uri);
    if (!doc) return null;

    const text = doc.getText();
    const offset = doc.offsetAt(params.position);

    // Extract word at cursor
    const before = text.substring(0, offset);
    const after = text.substring(offset);
    const wordStart = before.match(/(\w+)$/)?.[1] || '';
    const wordEnd = after.match(/^(\w+)/)?.[1] || '';
    const word = wordStart + wordEnd;

    if (!word) return null;

    // Check builtins
    if (BUILTINS[word]) {
        return {
            contents: {
                kind: MarkupKind.Markdown,
                value: `**${word}**\n\n\`\`\`kr\n${BUILTINS[word].sig}\n\`\`\`\n\n${BUILTINS[word].doc}`
            }
        };
    }

    // Check keywords
    if (KEYWORDS.includes(word)) {
        const kwDocs: Record<string, string> = {
            'fn': 'Declare a function.',
            'struct': 'Define a struct type.',
            'enum': 'Define an enumeration.',
            'match': 'Match an expression against multiple arms.',
            'import': 'Import another KernRift source file.',
            'type': 'Create a type alias.',
            'static': 'Declare a static (global) variable.',
            'unsafe': 'Mark a block for raw pointer operations.',
            'if': 'Conditional branch.',
            'while': 'Loop while condition is true.',
            'for': 'Iterate over a range: `for i in start..end`.',
            'return': 'Return a value from a function.',
            'break': 'Exit a loop.',
            'continue': 'Skip to next loop iteration.',
        };
        if (kwDocs[word]) {
            return { contents: { kind: MarkupKind.Markdown, value: `**${word}** — ${kwDocs[word]}` } };
        }
    }

    // Check types
    if (TYPES.includes(word)) {
        const sizes: Record<string, string> = {
            'uint8': '8-bit unsigned (1 byte)', 'uint16': '16-bit unsigned (2 bytes)',
            'uint32': '32-bit unsigned (4 bytes)', 'uint64': '64-bit unsigned (8 bytes)',
            'int8': '8-bit signed', 'int16': '16-bit signed',
            'int32': '32-bit signed', 'int64': '64-bit signed',
            'bool': 'Boolean (true/false)', 'char': 'ASCII character (1 byte)',
        };
        return { contents: { kind: MarkupKind.Markdown, value: `**${word}** — ${sizes[word] || 'Type alias'}` } };
    }

    // Check functions in file
    const fnMatch = text.match(new RegExp(`fn\\s+${word}\\s*\\(([^)]*)\\)(?:\\s*->\\s*(\\w+))?`));
    if (fnMatch) {
        const params = fnMatch[1];
        const ret = fnMatch[2] ? ` -> ${fnMatch[2]}` : '';
        return {
            contents: {
                kind: MarkupKind.Markdown,
                value: `\`\`\`kr\nfn ${word}(${params})${ret}\n\`\`\``
            }
        };
    }

    return null;
});

// --- Go to Definition ---

connection.onDefinition((params: DefinitionParams): Location | null => {
    const doc = documents.get(params.textDocument.uri);
    if (!doc) return null;

    const text = doc.getText();
    const offset = doc.offsetAt(params.position);

    const before = text.substring(0, offset);
    const after = text.substring(offset);
    const wordStart = before.match(/(\w+)$/)?.[1] || '';
    const wordEnd = after.match(/^(\w+)/)?.[1] || '';
    const word = wordStart + wordEnd;

    if (!word) return null;

    // Search for function definition
    const fnRegex = new RegExp(`fn\\s+${word}\\s*\\(`, 'g');
    const match = fnRegex.exec(text);
    if (match) {
        const pos = doc.positionAt(match.index);
        return Location.create(params.textDocument.uri, Range.create(pos, pos));
    }

    // Search for struct definition
    const structRegex = new RegExp(`struct\\s+${word}\\s*\\{`, 'g');
    const sMatch = structRegex.exec(text);
    if (sMatch) {
        const pos = doc.positionAt(sMatch.index);
        return Location.create(params.textDocument.uri, Range.create(pos, pos));
    }

    // Search for enum definition
    const enumRegex = new RegExp(`enum\\s+${word}\\s*\\{`, 'g');
    const eMatch = enumRegex.exec(text);
    if (eMatch) {
        const pos = doc.positionAt(eMatch.index);
        return Location.create(params.textDocument.uri, Range.create(pos, pos));
    }

    return null;
});

documents.listen(connection);
connection.listen();
