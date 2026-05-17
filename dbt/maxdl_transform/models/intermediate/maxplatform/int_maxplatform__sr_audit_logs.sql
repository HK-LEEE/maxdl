-- 자동생성: maxplatform.sr_audit_logs Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__sr_audit_logs')) }}
from {{ ref('stg_maxplatform__sr_audit_logs') }}
