-- 자동생성: maxplatform.ct_stage_notification_rules Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__ct_stage_notification_rules')) }}
from {{ ref('stg_maxplatform__ct_stage_notification_rules') }}
