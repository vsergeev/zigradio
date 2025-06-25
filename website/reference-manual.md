---
permalink: reference-manual.html
layout: refman.njk
templateEngineOverride: njk,md

categories:
  - Sources
  - Sinks
  - Filtering
  - Math Operations
  - Level Control
  - Sample Rate Manipulation
  - Spectrum Manipulation
  - Carrier and Clock Recovery
  - Digital
  - Type Conversion
  - Miscellaneous
  - Demodulation
---

# ZigRadio Reference Manual

Generated from ZigRadio `{{ version.git_tag_long }}`.

## Example

Coming soon...

## Building

Coming soon...

## Running

Coming soon...

## Blocks

{% for category in categories %}

### {{ category }}

{% for block, tags in refman.blocks[category] %}

#### {{ block }}

<div class="block">

{{ tags['@description'][0] }}

{% set ctparamlist -%}
{%- set comma = joiner(', ') -%}
{%- for ctparam in tags['@ctparam'] -%}
{{ comma() }}comptime {{ ctparam.split(' ')[0] }}: {{ ctparam.split(' ')[1] }}
{%- endfor -%}
{%- endset -%}
{%- set paramlist -%}
{%- set comma = joiner(', ') -%}
{%- for param in tags['@param'] -%}
{{ comma() }}{{ param.split(' ')[0] }}: {{ param.split(' ')[1] }}
{%- endfor -%}
{%- endset -%}

##### `radio.blocks.{{ block }}{{ "(" + ctparamlist + ")" if tags['@ctparam'] else "" }}.init({{ paramlist }})`

{%if tags['@ctparam'] %}

###### Comptime Arguments

{% for ctparam in tags['@ctparam'] %}
{% set fields = ctparam.split(' ') %}

- `{{ fields[0] }}` (_{{ fields[1] }}_): {{ fields.slice(2).join(' ') }}

{% endfor %}
{% endif %}

{%if tags['@param'] %}

###### Arguments

{% for param in tags['@param'] %}
{% set fields = param.split(' ') %}

- `{{ fields[0] }}` (_{{ fields[1] }}_): {{ fields.slice(2).join(' ') }}

{% endfor %}
{% endif %}

###### Type Signature

{% set fields = tags['@signature'][0].split(' ') %}
{% set inputs = fields.slice(0, fields.indexOf('>')) %}
{% set outputs = fields.slice(fields.indexOf('>') + 1) %}
{% set representation = "➔❑➔" if inputs.length > 0 and outputs.length > 0 else ("➔❑" if inputs.length > 0 else "❑➔") %}

{%- set comma1 = joiner(', ') -%}
{%- set comma2 = joiner(', ') -%}

- {% for input in inputs %}{{ comma1() }}`{{ input.split(':')[0] }}` _{{ input.split(':')[1] }}_{% endfor %} {{ representation }} {% for output in outputs %}{{ comma2() }}`{{ output.split(':')[0] }}` _{{ output.split(':')[1] }}_{% endfor %}

{%if tags['@usage'] %}

###### Example

```zig
{{ tags['@usage'][0] | safe }}
```

{% endif %}

</div>

---

{% endfor %}

{% endfor %}
