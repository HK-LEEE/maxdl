-- 자동생성: maxplatform.sr_task_templates Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__sr_task_templates')) }}
from {{ ref('stg_maxplatform__sr_task_templates') }}
