/*
  적재모드 → dbt 증분전략 매핑 (데이터주도)
  ---------------------------------------------------------------------------
  ingestion-map 의 모드를 Silver/Gold 증분전략으로 변환(계획서 §1·§5).
    append  → append            (커서 워터마크로 누적, 필요시 dedup)
    replica → (전체 재구성)      → 모델에서 materialized=table 권장
    merge   → merge             (unique_key 기준 upsert; PK 불안정 시 delete+insert)
  사용: {{ maxdl_incremental_strategy('merge') }}
*/
{% macro maxdl_incremental_strategy(mode) %}
    {%- set m = {
        'append':  'append',
        'replica': 'append',
        'merge':   'merge'
    } -%}
    {%- if mode not in m -%}
        {{ exceptions.raise_compiler_error("알 수 없는 적재모드: " ~ mode) }}
    {%- endif -%}
    {{ return(m[mode]) }}
{% endmacro %}
