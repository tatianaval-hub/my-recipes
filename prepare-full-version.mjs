import fs from 'node:fs';
let html = fs.readFileSync('index.html', 'utf8');
function replaceOnce(oldText, newText) {
  if (html.split(oldText).length !== 2) throw new Error('Source mismatch: ' + oldText.slice(0, 80));
  html = html.replace(oldText, () => newText);
}
const oldImport = "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';";
replaceOnce(oldImport, "import { createClient } from './vendor/supabase.js';");
const helpers = `
    let readToken=null,readEpoch=0,loadVersion=0,actionVersion=0,loadedUser=null;
    const detailCache=new Map(),detailPending=new Map(),readControllers=new Set();
    const listFields='id,title,category,cooking_time,servings,description,ingredients,notes,is_favorite,image_url,updated_at';
    const detailFields=listFields+',steps,source_url';
    function resetReads(){
      readEpoch++;loadVersion++;actionVersion++;readToken=null;loadedUser=null;
      detailCache.clear();detailPending.clear();
      for(const c of readControllers)c.abort();readControllers.clear();recipes=[];
      for(const id of ['recipeDialog','detailDialog'])if($(id).open)$(id).close();
      $('recipeForm').reset();$('detailContent').replaceChildren();$('recipeList').replaceChildren();
    }
    async function readRecipes(params){
      if(!readToken)throw new Error('Войдите снова.');
      const c=new AbortController(),start=performance.now();readControllers.add(c);
      let phase='ожидание заголовков',timedOut=false;
      const timer=setTimeout(()=>{timedOut=true;c.abort();},25000);
      try{
        const response=await fetch(SUPABASE_URL+'/rest/v1/recipes?'+new URLSearchParams(params),{headers:{apikey:SUPABASE_PUBLISHABLE_KEY,Authorization:'Bearer '+readToken},signal:c.signal,cache:'no-store'});
        const headersAt=performance.now();phase='чтение ответа';
        const text=await response.text(),bodyAt=performance.now();let data;
        try{data=text?JSON.parse(text):null;}catch{throw new Error('Ответ не является JSON. HTTP '+response.status);}
        if(!response.ok)throw new Error('HTTP '+response.status+': '+(data?.message||'Ошибка чтения'));
        if(!Array.isArray(data))throw new Error('Ожидался список рецептов.');
        return {data,timing:'до заголовков '+((headersAt-start)/1000).toFixed(2)+' с; чтение '+((bodyAt-headersAt)/1000).toFixed(2)+' с; всего '+((performance.now()-start)/1000).toFixed(2)+' с'};
      }catch(error){if(error.name==='AbortError')throw new Error(timedOut?'Запрос прерван через 25 секунд: '+phase+'.':'Запрос отменён.');throw error;}
      finally{clearTimeout(timer);readControllers.delete(c);}
    }
    async function load(){
      const generation=readEpoch,version=++loadVersion;detailCache.clear();detailPending.clear();actionVersion++;
      const collected=[];status('Полная версия: загрузка рецептов…');
      try{
        for(let offset=0;;offset+=50){
          const result=await readRecipes({select:listFields,order:'updated_at.desc,id.asc',offset:String(offset),limit:'50'});
          if(generation!==readEpoch||version!==loadVersion)return;
          collected.push(...result.data);recipes=collected.slice();render();
          status('Загружено '+recipes.length+'. '+result.timing);
          if(result.data.length<50)break;
        }
        loadedUser=currentUser?.id||null;
        status('Полная версия · рецептов: '+recipes.length+' · чтение завершено');
      }catch(error){if(generation===readEpoch&&version===loadVersion){status('Ошибка загрузки: '+error.message+(collected.length?' Показана только загруженная часть списка.':''));}}
    }
    function fetchFullRecipe(id){
      if(detailCache.has(id))return Promise.resolve(detailCache.get(id));
      if(detailPending.has(id))return detailPending.get(id);
      const generation=readEpoch,version=loadVersion;
      const promise=readRecipes({select:detailFields,id:'eq.'+id,limit:'1'}).then(result=>{
        if(generation!==readEpoch||version!==loadVersion)return null;
        const r=result.data[0];if(!r)throw new Error('Рецепт не найден или недоступен.');
        detailCache.set(id,r);const i=recipes.findIndex(x=>x.id===id);if(i>=0)recipes[i]={...recipes[i],...r};
        status('Рецепт загружен: '+result.timing);return r;
      }).finally(()=>{if(detailPending.get(id)===promise)detailPending.delete(id);});
      detailPending.set(id,promise);return promise;
    }
    async function recipeAction(id,callback){
      const generation=readEpoch,action=++actionVersion,cached=detailCache.has(id);
      if(!cached)status('Загрузка полного рецепта…');
      try{
        const r=await fetchFullRecipe(id);
        if(!r||generation!==readEpoch||action!==actionVersion)return;
        if(cached)status('Рецепт из памяти страницы — без нового запроса');
        await callback(id);
      }catch(error){if(generation===readEpoch&&action===actionVersion)status('Не удалось открыть рецепт: '+error.message);}
    }
    function detail(id){return recipeAction(id,showDetail);}
    function edit(id){return recipeAction(id,showEditor);}
    function shareRecipe(id){return recipeAction(id,shareLoadedRecipe);}
`;
const start=html.indexOf('    async function load(){');
const end=html.indexOf('    function clear()',start);
if(start<0||end<0)throw new Error('Load function boundaries not found.');
html=html.slice(0,start)+helpers+'\n'+html.slice(end);
replaceOnce('function edit(id){const r=recipes.find(x=>x.id===id);','function showEditor(id){const r=recipes.find(x=>x.id===id);');
replaceOnce('function detail(id)\n','function showDetail(id)\n');
replaceOnce('async function shareRecipe(id){','async function shareLoadedRecipe(id){');
const sessionStart=html.indexOf('    async function onSession(s){');
const sessionEnd=html.indexOf("$('authForm').addEventListener",sessionStart);
if(sessionStart<0||sessionEnd<0)throw new Error('Session boundaries not found.');
html=html.slice(0,sessionStart)+`    async function onSession(s){
      const user=s?.user||null,changed=user?.id!==currentUser?.id;
      if(changed||!user)resetReads();
      currentUser=user;readToken=s?.access_token||null;
      if(!user){visible(false);$('authPassword').value='';return;}
      visible(true);$('userEmail').textContent=user.email||'';$('authPassword').value='';
      if(loadedUser!==user.id)await load();
    }
    `+html.slice(sessionEnd);
replaceOnce("function clear(){$('recipeForm').reset();", "function clear(){actionVersion++;$('recipeForm').reset();");
replaceOnce("$('detailDialog').showModal();", "if(!$('detailDialog').open)$('detailDialog').showModal();");
replaceOnce("const photoStyle=u=>u?", "const photoStyle=value=>{let u='';try{const parsed=new URL(value);if(parsed.protocol==='https:'||parsed.protocol==='http:')u=parsed.href;}catch{}return u?");
replaceOnce(":'';const fmtMeta=r=>", ":'';};const fmtMeta=r=>");
replaceOnce(".replace(/'/g,'%27')", ".replace(/'/g,'%27').replace(/\"/g,'%22').replace(/</g,'%3C').replace(/>/g,'%3E').replace(/&/g,'%26')");
replaceOnce("${escapeHtml(r.description).slice(0,150)}", "${escapeHtml(r.description.slice(0,150))}");
replaceOnce("${r.source_url?`<a", "${/^https?:\\/\\//i.test(r.source_url||'')?`<a");
if(html.includes('esm.sh/'))throw new Error('External esm.sh import remains.');
if(html.includes(".select('*')"))throw new Error('Wildcard read remains.');
fs.mkdirSync('dist',{recursive:true});fs.writeFileSync('dist/index.html',html);
console.log('Prepared full recipe app: explicit REST reads, paging, detail cache, existing editor and authentication.');
