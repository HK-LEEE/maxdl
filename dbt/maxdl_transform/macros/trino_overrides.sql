/*
  Trino/Iceberg 호환 매크로 오버라이드 — maxdl
  ---------------------------------------------------------------------------
  [필수] dbt-trino 기본 current_timestamp 는 TIMESTAMP(3) WITH TIME ZONE 를
  내는데 Apache Iceberg 는 이를 거부한다(정밀도 6 필요). 미오버라이드 시
  snapshot/감사컬럼 생성이 전부 실패하므로 반드시 둔다.
*/
{% macro trino__current_timestamp() %}
    cast(current_timestamp as timestamp(6) with time zone)
{% endmacro %}

/* 감사 컬럼 표준(모든 Silver/Gold 모델에서 재사용) */
{% macro maxdl_audit_columns() %}
    cast(current_timestamp as timestamp(6) with time zone) as _maxdl_loaded_at,
    '{{ invocation_id }}' as _maxdl_run_id
{% endmacro %}
