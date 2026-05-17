-- 자동생성: maxplatform.maxmes_operation Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__maxmes_operation')) }}
from {{ ref('stg_maxplatform__maxmes_operation') }}
