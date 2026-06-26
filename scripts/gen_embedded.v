import os

fn main() {
    dir := 'syntax'
    files := os.ls(dir) or { panic(err) }
    mut yaml_files := []string{}
    for f in files {
        if f.ends_with('.yaml') {
            yaml_files << f
        }
    }
    yaml_files.sort()

    mut out := os.create('syntax_embedded.v') or { panic(err) }
    defer { out.close() }

    out.writeln('module main') or { panic(err) }
    out.writeln('') or { panic(err) }
    out.writeln('// Auto-generated. DO NOT EDIT. Run: v run scripts/gen_embedded.v') or { panic(err) }
    out.writeln('// Embeds all syntax YAML files into the binary so highlighting works') or { panic(err) }
    out.writeln('// even when syntax/ is not installed on disk (e.g. wax/brew installs).') or { panic(err) }
    out.writeln('') or { panic(err) }
    out.writeln('fn embedded_syntax_yaml(ft string) ?string {') or { panic(err) }
    out.writeln('\treturn match ft {') or { panic(err) }
    for f in yaml_files {
        name := f.replace('.yaml', '')
        out.writeln("\t\t'${name}' { \$embed_file('syntax/${f}').to_string() }") or { panic(err) }
    }
    out.writeln('\t\telse { none }') or { panic(err) }
    out.writeln('\t}') or { panic(err) }
    out.writeln('}') or { panic(err) }
}
