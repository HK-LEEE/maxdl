-- 자동생성: pfms.pbatstsdat Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_pfms__pbatstsdat')) }}
from {{ ref('stg_pfms__pbatstsdat') }}
