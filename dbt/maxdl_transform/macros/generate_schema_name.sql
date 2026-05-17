/*
  스키마명 생성 오버라이드 — maxdl
  ---------------------------------------------------------------------------
  dbt 기본 동작은 <target.schema>_<custom_schema> 로 접두를 붙여
  silver_staging / silver_silver 처럼 어색해진다. 본 프로젝트는 계층 스키마를
  staging/silver/gold/meta 로 "그대로" 쓰므로, custom schema 가 지정되면
  접두 없이 그대로 사용한다(미지정 시에만 target.schema).
*/
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
