/*
  Iceberg 테이블 공통 속성 — maxdl
  ---------------------------------------------------------------------------
  Silver/Gold 모델에서 재사용할 Iceberg 기본 속성(파일포맷/파티셔닝 헬퍼).
  dbt-trino 의 table properties 규약에 맞춰 dict 반환.
*/
{% macro maxdl_iceberg_props(partition_by=none) %}
    {%- set props = {'format': 'PARQUET'} -%}
    {%- if partition_by is not none -%}
        {%- do props.update({'partitioning': partition_by}) -%}
    {%- endif -%}
    {{ return(props) }}
{% endmacro %}
