# beamtalk-yaml

YAML parsing and generation library for [Beamtalk](https://beamtalk.dev).

Built on [yamerl](https://github.com/yakaz/yamerl) (pure Erlang, no NIFs).

## Installation

Add the dependency to your `beamtalk.toml`:

```toml
[dependencies]
yaml = "0.1.0"
```

Then run:

```bash
beamtalk build
```

## Usage

### Parsing

```beamtalk
(Yaml parse: "answer: 42") unwrap           // => #{"answer" => 42}
(Yaml parse: "- 1\n- 2\n- 3") unwrap       // => #(1, 2, 3)
(Yaml parse: "null") unwrap                 // => nil
```

### Multi-document parsing

```beamtalk
(Yaml parseAll: "42\n---\n43") unwrap       // => #(42, 43)
```

### Generation

```beamtalk
Yaml generate: #{"name" => "Ada"}           // => "{\"name\": \"Ada\"}"
Yaml generate: #(1, 2, 3)                   // => "[1, 2, 3]"
Yaml generate: nil                          // => "null"
```

### File parsing

```beamtalk
(Yaml parseFile: "config.yaml") unwrap
```

## Type Mapping

| YAML          | Beamtalk     |
|---------------|--------------|
| mapping       | Dictionary   |
| sequence      | List         |
| string        | String       |
| integer       | Integer      |
| float         | Float        |
| true/false    | Boolean      |
| null/~        | nil          |

## Classes

| Class | Description |
|-------|-------------|
| `Yaml` | Class methods for parsing and generating YAML strings |

## Development

```bash
just build    # Build the package
just test     # Run tests
just fmt      # Check formatting
just ci       # Full CI check (fmt + lint + build + test)
```

## License

Apache-2.0 -- Copyright 2026 James Casey
