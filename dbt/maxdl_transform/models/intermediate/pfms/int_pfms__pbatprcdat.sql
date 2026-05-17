-- 자동생성: pfms.pbatprcdat Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_pfms__pbatprcdat')) }}
from {{ ref('stg_pfms__pbatprcdat') }}
