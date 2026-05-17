-- 자동생성: maxplatform.sr_approval_rules Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__sr_approval_rules')) }}
from {{ ref('stg_maxplatform__sr_approval_rules') }}
