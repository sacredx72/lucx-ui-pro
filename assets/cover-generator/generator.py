#!/usr/bin/env python3
"""Offline static website generator; Python standard library only."""
import argparse
import hashlib
import html
import json
import math
import os
from pathlib import Path, PurePosixPath
import random
import re
import secrets
import shutil
import tempfile

HERE = Path(__file__).resolve().parent
OWNER = 'lucx-cover-generator'
VERSION = '1.0.0'
PALETTES = ['#628e7b', '#c38742', '#4f90bd', '#c07770', '#8d82b3', '#719da1', '#b29b55', '#79a078']
COMMON_CSS = '''*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0}a{color:inherit;text-underline-offset:4px}p{line-height:1.7}nav a{display:inline-block;margin:5px 14px 5px 0;font-size:13px}button,input,select{font:inherit}button{cursor:pointer;border:1px solid var(--accent);background:transparent;color:inherit;padding:10px 15px;border-radius:3px}button:hover,button[aria-pressed=true],button[aria-selected=true]{background:var(--accent);color:#fff}button:focus-visible,a:focus-visible,input:focus-visible,summary:focus-visible{outline:3px solid var(--accent);outline-offset:4px}input[type=search],input[type=number],select{max-width:100%;border:1px solid var(--accent);padding:11px;background:transparent;color:inherit}input[type=range]{width:100%;accent-color:var(--accent)}small,label{line-height:1.5}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:12px 10px;text-align:left;border-bottom:1px solid #85959f55}th{font-weight:600}pre{overflow:auto;border:1px solid #85959f55;padding:20px;font-size:13px;line-height:1.65}summary{cursor:pointer;line-height:1.5}details{padding:13px 0;border-bottom:1px solid #85959f55}details p{margin-bottom:10px}svg{display:block;width:100%;height:auto}.diagram{margin:20px 0}.figure-note{font:11px monospace;opacity:.75;margin-top:10px}.metrics{display:flex;flex-wrap:wrap;gap:20px;padding:20px 0}.metric{flex:1;min-width:100px}.metric strong{display:block;font-size:29px}.metric small{display:block;margin-top:5px}.note{padding:12px 0;border-bottom:1px solid #85959f55}.glossary dt{font-weight:bold;margin-top:18px}.glossary dd{margin:8px 0;font-size:13px;line-height:1.7}.story-section{margin:35px 0}.story-section p{max-width:760px}.steps{padding-left:25px;line-height:1.8}.steps li{padding:10px 0}.tab-strip{display:flex;gap:8px;flex-wrap:wrap;margin:25px 0 15px}.tab-panel{padding:20px 0}.search-label{display:block;font-size:12px;margin:15px 0 8px}.search{width:100%}.filters{display:flex;flex-wrap:wrap;gap:8px;margin:20px 0}.searchable[hidden],.tab-panel[hidden],tr[hidden],.filter-item[hidden]{display:none!important}.quiz output{display:block;margin-top:20px;line-height:1.7}.checklist input[type=checkbox],.task input{width:18px;height:18px;flex-shrink:0;accent-color:var(--accent)}.task:has(input:checked){opacity:.6}.part-info{min-height:55px;font-size:13px}.selected-part{stroke:var(--accent)!important;stroke-width:4!important}.signal-path{stroke:var(--accent);fill:none;stroke-width:3}.schedule-header{font-size:12px;letter-spacing:2px}footer{margin-top:30px;font-size:12px;line-height:1.8;opacity:.8}.nav-current{font-weight:bold;text-decoration:none;border-bottom:2px solid var(--accent)}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}@media(max-width:850px){.edition,.console,.wiki,.notebook,.manual,.catalog,.poster-grid,.compare-detail,.drawing,.road-bottom,.course,.directory,.kanban,.atlas,.material-lead,.blueprint-grid,.blueprint-notes,.bulletin,.studio-cover,.schedule-body,.signal-bottom,.inspection,.data-two,.terminal-columns{display:block!important}.wiki aside,.notebook aside,.manual aside,.course aside,.inspection aside{border:0;position:static}.wiki nav a,.notebook nav a,.manual nav a,.course nav a,.inspection nav a{display:inline-block;margin-right:15px}.manual-rail{border:0}.console section,.poster-grid section,.kanban-column{margin-bottom:20px}.drawing aside,.atlas aside{border:0;padding:25px}.milestones,.swatches,.card-wall{grid-template-columns:repeat(2,1fr)!important}.flow{flex-direction:column}.flow-stage:after{content:none!important}.studio-story{columns:1}.optics-lead{display:block}.gallery{grid-template-columns:1fr!important}.gallery figure:first-child{grid-row:auto}.dataset-toolbar{flex-wrap:wrap}h1{overflow-wrap:anywhere}.paper h1{font-size:45px}.paper h2{font-size:36px}.wiki main,.course main,.inspection main,.notebook main{padding:30px}.terminal{margin:20px}.product{min-width:0}table{display:block;overflow-x:auto}}@media(max-width:500px){.inventory,.swatches,.milestones,.card-wall{grid-template-columns:1fr!important}.essay,.dataset,.materials,.poster{padding:25px}.essay h1,.optics-lead h1,.history-intro h1{font-size:42px}.portfolio-intro header,.studio-head,.catalog-head,.blueprint-top{display:block}.blueprint{margin:12px;padding:20px}.drawing-canvas{padding:20px}.history-intro{padding:0 20px}.history{margin-left:25px}.console{padding:20px}}
'''

SCRIPT = r'''document.addEventListener('DOMContentLoaded',()=>{
document.querySelectorAll('[data-search]').forEach(input=>input.addEventListener('input',()=>{const q=input.value.toLowerCase();document.querySelectorAll('.searchable').forEach(item=>{item.dataset.searchHidden=String(!item.textContent.toLowerCase().includes(q));item.hidden=item.dataset.searchHidden==='true'||item.dataset.filterHidden==='true';});}));
document.querySelectorAll('[data-filter]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('[data-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));document.querySelectorAll('.filter-item').forEach(item=>{item.dataset.filterHidden=String(button.dataset.filter!=='all'&&item.dataset.category!==button.dataset.filter);item.hidden=item.dataset.filterHidden==='true'||item.dataset.searchHidden==='true';});}));
document.querySelectorAll('[data-tab]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('[data-tab]').forEach(b=>b.setAttribute('aria-selected',String(b===button)));document.querySelectorAll('[data-panel]').forEach(p=>p.hidden=p.dataset.panel!==button.dataset.tab);}));
document.querySelectorAll('[data-slider]').forEach(input=>{const update=()=>{document.querySelectorAll('[data-value]').forEach(v=>v.textContent=input.value);const trace=document.querySelector('.signal-path');if(trace){const a=Number(input.value);let d='';for(let x=0;x<=800;x+=4)d+=(x?' L':'M')+x+' '+(130+Math.sin(x/42)*a*.8).toFixed(2);trace.setAttribute('d',d);}};input.addEventListener('input',update);update();});
const conversion=document.querySelector('[data-convert]');if(conversion){const update=()=>{const number=Number(conversion.value);document.querySelector('[data-converted]').textContent=Number.isFinite(number)?(number/25.4).toFixed(4)+' in':'Enter a number';};conversion.addEventListener('input',update);update();}
document.querySelectorAll('[data-command]').forEach(button=>button.addEventListener('click',()=>{document.querySelector('[data-command-output]').textContent=button.dataset.output;}));
document.querySelectorAll('[data-quiz]').forEach(button=>button.addEventListener('click',()=>{document.querySelector('[data-quiz-output]').textContent=button.dataset.feedback;}));
document.querySelectorAll('[data-part]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('[data-part-shape]').forEach(shape=>shape.classList.toggle('selected-part',shape.dataset.partShape===button.dataset.part));document.querySelector('[data-part-info]').textContent=button.dataset.description;}));
document.querySelectorAll('[data-sort]').forEach(button=>button.addEventListener('click',()=>{const body=document.querySelector('[data-sort-body]');if(!body)return;const asc=button.dataset.direction!=='asc';button.dataset.direction=asc?'asc':'desc';[...body.rows].sort((a,b)=>(Number(a.dataset.value)-Number(b.dataset.value))*(asc?1:-1)).forEach(row=>body.appendChild(row));}));
document.querySelectorAll('[data-milestone]').forEach(button=>button.addEventListener('click',()=>{document.querySelector('[data-milestone-output]').textContent=button.dataset.detail;}));
document.querySelectorAll('[data-compare]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('[data-compare-row]').forEach(row=>row.hidden=button.dataset.compare!=='all'&&row.dataset.compareRow!==button.dataset.compare);document.querySelectorAll('[data-compare]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));}));
});'''

def esc(value):
    return html.escape(str(value), quote=True)

def load_json(path):
    return json.loads(path.read_text(encoding='utf-8'))

def diagram(rng, accent, kind='assembly'):
    if kind=='constellation':
        points=[(rng.randint(35,765),rng.randint(30,360)) for _ in range(20)]
        paths=' '.join(f'{x},{y}' for x,y in points[:9])
        shapes=f'<polyline points="{paths}" stroke="{accent}" fill="none" opacity=".5"/>'
        shapes+=''.join(f'<circle cx="{x}" cy="{y}" r="{rng.randint(2,5)}" fill="currentColor"/>' for x,y in points)
    elif kind in ('photography','travel','art'):
        shapes=f'<rect x="0" y="0" width="800" height="400" fill="{accent}" fill-opacity=".2"/><circle cx="620" cy="90" r="50" fill="{accent}" fill-opacity=".6"/><path d="M0 310L210 100L430 350L610 140L800 280V400H0Z" fill="{accent}"/><path d="M0 370L340 220L610 370L800 260V400H0Z" fill="currentColor" fill-opacity=".2"/>'
    elif kind=='nature':
        shapes='<path d="M400 365V55" fill="none" stroke="currentColor" stroke-width="4"/>'
        shapes+=''.join(f'<ellipse cx="{400+(-1 if i%2 else 1)*65}" cy="{85+i*42}" rx="85" ry="24" transform="rotate({-30 if i%2 else 30} {400+(-1 if i%2 else 1)*65} {85+i*42})" fill="{accent}" fill-opacity="{.3+i*.08}"/>' for i in range(6))
    elif kind=='culinary':
        shapes=f'<rect x="0" y="0" width="800" height="400" fill="{accent}" fill-opacity=".12"/><ellipse cx="390" cy="320" rx="200" ry="25" fill="currentColor" fill-opacity=".1"/><path d="M260 110H500V240Q500 315 380 315Q260 315 260 240Z" fill="{accent}"/><path d="M500 130H550Q600 130 600 195Q600 255 500 255" fill="none" stroke="{accent}" stroke-width="20"/><path d="M320 65Q300 40 320 15M390 65Q370 40 390 15M460 65Q440 40 460 15" fill="none" stroke="currentColor" opacity=".3" stroke-width="3"/>'
    elif kind in ('craft','books'):
        shapes=''.join(f'<rect x="{90+i*120}" y="{75+(i%2)*35}" width="100" height="230" rx="5" fill="{accent}" fill-opacity="{.3+i*.12}" stroke="currentColor"/><path d="M{105+i*120} {90+(i%2)*35}V{290+(i%2)*35}" stroke="currentColor" opacity=".4"/>' for i in range(5))
    elif kind in ('design','architecture','music'):
        shapes=''.join(f'<rect x="{40+i*125}" y="{70+(i%3)*40}" width="110" height="{220-(i%3)*25}" fill="{accent}" fill-opacity="{.2+i*.12}"/><circle cx="{95+i*125}" cy="{180+(i%2)*40}" r="40" fill="none" stroke="currentColor" stroke-width="2"/>' for i in range(6))
    else:
        shapes='<path d="M60 210H740 M160 65V340 M650 65V340" stroke="currentColor" opacity=".2" stroke-dasharray="5 7"/>'
        for i in range(5):
            x=75+i*135; y=100+(i%2)*35
            shapes+=f'<rect data-part-shape="{i}" x="{x}" y="{y}" width="110" height="{120+(i%3)*30}" rx="{rng.choice([0,6,20])}" fill="{accent}" fill-opacity=".15" stroke="currentColor" stroke-width="2"/>'
            shapes+=f'<circle cx="{x+55}" cy="{y+65}" r="{20+i*3}" fill="none" stroke="currentColor"/><text x="{x+10}" y="{y+25}" fill="currentColor" font-size="13">{i+1:02d}</text>'
        shapes+='<path d="M40 320H750 M40 310V330 M750 310V330" stroke="currentColor"/><text x="340" y="345" fill="currentColor" font-size="12">REFERENCE GEOMETRY</text>'
    return f'<div class="diagram"><svg viewBox="0 0 800 400" role="img" aria-label="Illustrative {kind} diagram">{shapes}</svg><p class="figure-note">Illustrative diagram; not a measured or manufacturing drawing.</p></div>'

def chart(rng, accent):
    values=[rng.randint(35,145) for _ in range(12)]
    points=' '.join(f'{50+i*62},{210-v}' for i,v in enumerate(values))
    lines=''.join(f'<line x1="40" y1="{y}" x2="760" y2="{y}" stroke="currentColor" opacity=".15"/>' for y in [50,100,150,200])
    return f'<div class="diagram"><svg viewBox="0 0 800 250" role="img" aria-label="Illustrative comparison chart">{lines}<polyline points="{points}" stroke="{accent}" stroke-width="3" fill="none"/><text x="45" y="238" fill="currentColor" font-size="12">REFERENCE SERIES · NORMALIZED VALUES</text></svg><p class="figure-note">Illustrative reference data, not live measurements.</p></div>'

def table(rng, count=6, data=False):
    rows=''
    for i in range(count):
        value=rng.randint(20,95)
        category=['geometry','surface','assembly'][i%3]
        rows+=f'<tr class="searchable" data-value="{value}" data-compare-row="{category}"><td>R-{i+1:03d}</td><td>{category.title()}</td><td>{value}</td><td>{["Reference","Comparison","Control"][i%3]}</td></tr>'
    return '<table><caption class="figure-note">Illustrative reference series</caption><thead><tr><th scope="col">Record</th><th scope="col">Category</th><th scope="col">Normalized value</th><th scope="col">Role</th></tr></thead><tbody'+(' data-sort-body' if data else '')+'>'+rows+'</tbody></table>'

def make_page(family, topic, names, rng, page_title, page_index, page_titles, generation):
    accent=names['accent']
    facts=topic['facts']
    intro=topic['intro']
    title=topic['title'] if page_index==0 else page_title+' / '+topic['title']
    brand=names['first']+' '+names['last']
    def link(i):
        return '/' if i==0 else f'/_lucx-cover/{generation}/page-{i:02d}.html'
    nav=''.join(f'<a href="{link(i)}"'+(' class="nav-current" aria-current="page"' if i==page_index else '')+'>'+esc(t)+'</a>' for i,t in enumerate(page_titles))
    if len(page_titles)==1:
        nav='<a href="#reference-notes">Notes</a>'
    notes=''.join(f'<div class="note searchable"><b>{label}</b><p>{esc(fact)}</p></div>' for label,fact in zip(['01 / Definition','02 / Method','03 / Observation','04 / Interpretation'],facts))
    terms=[('Reference','A stated basis for comparing observations.'),('Resolution','The smallest change represented by a measuring system.'),('Repeatability','The consistency of observations under the same conditions.'),('Boundary','The conditions and limits chosen for a study.')] if topic['group']=='technical' else [('Observation','A detail noticed and recorded in its original context.'),('Sequence','The order in which objects, images or ideas are arranged.'),('Context','The place, time and circumstances surrounding a note.'),('Collection','A group of studies brought together for a stated purpose.')]
    glossary='<dl class="glossary">'+''.join(f'<dt>{word}</dt><dd>{meaning}</dd>' for word,meaning in terms)+'</dl>'
    search='<label class="search-label" for="search">Search this page</label><input id="search" class="search" type="search" data-search placeholder="Type a keyword" autocomplete="off">'
    filters='<div class="filters" aria-label="Categories">'+''.join(f'<button type="button" data-filter="{key}" aria-pressed="{str(i==0).lower()}">{label}</button>' for i,(key,label) in enumerate([('all','All'),('geometry','Geometry'),('surface','Surface'),('assembly','Assembly')]))+'</div>'
    quote='<blockquote>'+esc(rng.choice(['A useful record explains what was observed and how it was observed.','Good comparisons begin with clear definitions.','Small details become visible when the reference stays consistent.']))+'</blockquote>'
    paragraphs=[f'{intro} {facts[page_index%4]} A useful working note records the context and the purpose of the study. Keep the details that explain what was noticed, and distinguish them from ideas that emerged later.',
                f'{facts[(page_index+1)%4]} When revisiting a series of observations, begin with the original context. Record the order of the work and keep the first descriptions alongside any later interpretation.',
                f'The next pass through {topic["title"].lower()} focuses on comparison. {facts[(page_index+2)%4]} Look for the relationships between the details and retain enough context for another reader to understand the study.'
                ]
    section_names=['Establishing a reference','Describing the setup','Reading the first observation','Working with variation','Comparing the records','Interpreting a diagram','Recording the conditions','Reviewing the method','A second pass','The limits of the study','Keeping useful notes','Questions for the next session']
    sections=''.join(f'<section class="story-section"><h2>{i+1:02d}. {heading}</h2><p>{esc(paragraphs[i%3])}</p><p>{esc(facts[(i+page_index)%4])} This point should be read together with the stated reference and the conditions of the record.</p></section>' for i,heading in enumerate(section_names[:family['sections']]))
    steps='<ol class="steps">'+''.join('<li><b>'+title+'</b><br>'+esc(description)+'</li>' for title,description in [('Define','State the reference and the purpose of the comparison.'),('Observe',facts[page_index%4]),('Record','Keep the conditions and observations together.'),('Review','Separate the result from the assumptions used to interpret it.')])+'</ol>'
    faq=''.join(f'<details class="searchable"><summary>{question}</summary><p>{esc(answer)}</p></details>' for question,answer in [('What does this reference describe?',intro),('What should accompany a measurement?',facts[0]),('Why keep the setup in the record?',facts[1]),('How should a comparison be read?',facts[2]),('What belongs in a working note?',facts[3]),('Are the plotted values live readings?','The diagrams and tables here use illustrative reference data. They are included to explain a reading method, not to report a live instrument.'),('What changes between sessions?','Review the reference, setup and conditions before combining records from different sessions.'),('Where should an interpretation begin?','Begin with the observation and its limits. An explanation should remain distinct from the original record.')])
    code='<pre><code>'+esc('record:\n  topic: '+topic['category']+'\n  reference: stated\n  conditions: recorded\n  method: comparison\n  values: illustrative\n  interpretation: separate')+'</code></pre>'
    hero=diagram(rng,accent,topic['category'] if topic['group']=='creative' else 'assembly')
    metrics='<div class="metrics">'+''.join(f'<div class="metric"><strong>{value}</strong><small>{label}</small></div>' for value,label in [('04','Reference stages'),(str(len(page_titles)),'Sections in this edition'),('SI','Unit convention')])+'</div>'
    tabs='<div class="tab-strip" role="tablist" aria-label="Reference views">'+''.join(f'<button id="tab-{i}" type="button" role="tab" aria-controls="panel-{i}" aria-selected="{str(i==0).lower()}" data-tab="{i}">{label}</button>' for i,label in enumerate(['Overview','Method','Observations']))+'</div>'+''.join(f'<section id="panel-{i}" role="tabpanel" aria-labelledby="tab-{i}" class="tab-panel" data-panel="{i}"'+(' hidden' if i else '')+f'><h2>{label}</h2><p>{esc(facts[i])}</p></section>' for i,label in enumerate(['Overview','Method','Observations']))
    products=''.join(f'<article class="product searchable filter-item" data-category="{category}">{diagram(rng,accent,topic["category"] if topic["group"]=="creative" else "assembly")}<small>REFERENCE {i+1:02d}</small><h2>{label} study</h2><p>{esc(facts[i%4])}</p><a href="{link((i%(len(page_titles)-1))+1) if len(page_titles)>1 else "#reference-notes"}">Read the record →</a></article>' for i,(category,label) in enumerate([('geometry','Contour'),('surface','Texture'),('assembly','Fit'),('geometry','Alignment'),('surface','Finish'),('assembly','Joint')]))
    slider='<label for="sweep">Illustrative amplitude: <output data-value>50</output></label><input id="sweep" data-slider type="range" min="5" max="100" value="50">'
    terminal='<div class="command-buttons">'+''.join(f'<button type="button" data-command="{name}" data-output="{esc(value)}">{name}</button>' for name,value in [('inspect','reference: stated\nconditions: recorded\nmode: illustrative'),('list','01 definition\n02 method\n03 observation\n04 interpretation'),('help','Choose inspect to read the reference settings.\nChoose list to view the record structure.')])+'</div><pre class="command-output" data-command-output>Choose a reference command above.</pre>'
    timeline=''.join(f'<article class="time-entry"><small>SESSION {i+1:02d}</small><h2>{heading}</h2><p>{esc(paragraphs[i%3])}</p>'+ (chart(rng,accent) if i%3==1 else '')+'</article>' for i,heading in enumerate(section_names[:family['sections']]))
    compare='<div>'+''.join(f'<button type="button" data-compare="{key}" aria-pressed="{str(key=="all").lower()}">{label}</button>' for key,label in [('all','All records'),('geometry','Geometry'),('surface','Surface'),('assembly','Assembly')])+'</div>'+table(rng,12)
    parts=''.join(f'<button type="button" class="part-button" data-part="{i}" data-description="{esc(facts[i%4])}">{i+1:02d} / {label}</button>' for i,label in enumerate(['Reference body','Alignment plane','Interface','Outer boundary','Inspection point']))+'<p class="part-info" data-part-info>Choose a part to highlight it in the diagram.</p>'
    milestones='<div class="milestones">'+''.join(f'<article class="milestone"><b>{i+1:02d}</b><h2>{label}</h2><p>{esc(facts[i])}</p><button type="button" data-milestone="{i}" data-detail="{esc(facts[i])}">Read note</button></article>' for i,label in enumerate(['Define','Prepare','Observe','Review']))+'</div><p data-milestone-output role="status">Choose a stage to read its working note.</p>'
    projects=''.join(f'<details class="project-card"'+(' open' if i==0 else '')+f'><summary>{i+1:02d} / {heading}</summary>{diagram(rng,accent,topic["category"])}<p>{esc(facts[i%4])}</p><a href="{link((i%(len(page_titles)-1))+1) if len(page_titles)>1 else "#reference-notes"}">Read the study →</a></details>' for i,heading in enumerate(['Contour and repetition','A reference surface','An aligned assembly','Reading the boundary']))
    quiz='<section class="quiz"><h2>Quick reading check</h2><p>Which note provides useful context?</p><button type="button" data-quiz data-feedback="Try again. A note is easier to interpret when its context is recorded.">A description with no context</button><button type="button" data-quiz data-feedback="Correct. The context helps a reader understand the observation.">An observation with its context recorded</button><button type="button" data-quiz data-feedback="Try again. A label alone does not explain an observation.">A label without an observation</button><output data-quiz-output aria-live="polite">Choose an answer.</output></section>'
    resources=''.join(f'<article class="resource searchable filter-item" data-category="{["geometry","surface","assembly"][i%3]}"><small>NOTE {i+1:02d}</small><h2>{heading}</h2><p>{esc(facts[i%4])}</p><a href="{link((i%(len(page_titles)-1))+1) if len(page_titles)>1 else "#reference-notes"}">Open reference →</a></article>' for i,heading in enumerate(section_names[:8]))
    checklist='<div class="checklist">'+''.join(f'<label><input type="checkbox"><span><b>{heading}</b><br>{esc(facts[i%4])}</span></label>' for i,heading in enumerate(['State the reference','Describe the setup','Record conditions','Read the observation','Compare the results','Review the assumptions']))+'</div>'
    board='<div class="kanban">'+''.join(f'<section class="kanban-column"><h2>{label}</h2>'+''.join(f'<div class="task"><label><input type="checkbox"><span>{esc(section_names[i*3+j])}</span></label><p>{esc(facts[(i+j)%4])}</p></div>' for j in range(3))+'</section>' for i,label in enumerate(['Prepare','Observe','Review']))+'</div>'
    swatches=''.join(f'<article class="swatch searchable filter-item" data-category="{["geometry","surface","assembly"][i%3]}"><div class="swatch-art" style="background:{PALETTES[i%len(PALETTES)]};color:white">{i+1:02d}</div><h2>{label}</h2><p>{esc(facts[i%4])}</p></article>' for i,label in enumerate(['Matte','Linear','Layered','Polished','Coarse','Fine','Continuous','Textured']))
    changelog=''.join(f'<article class="release"><small>WORKING NOTE {i+1:02d}</small><p><strong>{heading}</strong></p><p>{esc(paragraphs[i%3])}</p>{notes if i==1 else ""}</article>' for i,heading in enumerate(section_names[:family['sections']]))
    flow='<div class="flow">'+''.join(f'<div class="flow-stage"><small>{i+1:02d}</small><h2>{label}</h2><p>{esc(facts[i])}</p></div>' for i,label in enumerate(['Reference','Setup','Observation','Review']))+'</div>'
    gallery='<div class="gallery">'+''.join(f'<figure>{diagram(rng,accent,topic["category"])}<figcaption>STUDY {i+1:02d} / {label}</figcaption></figure>' for i,label in enumerate(['Contour','Alignment','Surface']))+'</div>'
    schedule='<div><p class="schedule-header">REFERENCE SESSION PLAN / NOT AN EVENT BOOKING</p>'+''.join(f'<article class="session"><time>{i*20:02d} min</time><div><h2>{label}</h2><p>{esc(facts[i%4])}</p></div></article>' for i,label in enumerate(['Set the reference','Prepare the assembly','Record a reading','Compare the sequence','Discuss the limits']))+'</div>'
    signal='<svg viewBox="0 0 800 270" role="img" aria-label="Illustrative adjustable sine wave"><path d="M0 130H800" stroke="currentColor" opacity=".3"/><path class="signal-path" d="M0 130L800 130"/></svg><p class="figure-note">Illustrative mathematical waveform, not an instrument reading.</p>'
    cards=''.join(f'<article class="index-card searchable"><small>INDEX {i+1:02d}</small><h2>{heading}</h2><p>{esc(facts[i%4])}</p><details><summary>Working note</summary><p>{esc(paragraphs[i%3])}</p></details></article>' for i,heading in enumerate(section_names[:9]))
    values={
        'ISSUE':f'FIELD EDITION / {generation[-6:].upper()}','BRAND':esc(brand),'TOPIC':esc(topic['title']), 'TOPIC_SLUG':esc(topic['category']), 'TITLE':esc(title), 'INTRO':esc(intro),
        'NAV':nav,'HERO':hero,'LONG_STORY':sections,'NOTES':notes,'GLOSSARY':glossary,'SUMMARY':'<p>'+esc(intro+' '+facts[(page_index+1)%4])+'</p>',
        'SECTIONS':sections,'CODE':code,'STEPS':steps,'FAQ':faq,'CHART':chart(rng,accent),'TABLE':table(rng),'METRICS':metrics,'TABS':tabs,'SEARCH':search,'FILTERS':filters,
        'PRODUCTS':products,'SLIDER':slider,'TERMINAL':terminal,'TIMELINE':timeline,'COMPARE':compare,'SCHEMATIC':hero,'PARTS':parts,'MILESTONES':milestones,
        'DATA_TABLE':table(rng,20,True),'PROJECTS':projects,'LESSON':sections,'QUIZ':quiz,'RESOURCES':resources,'BOARD':board,'CONSTELLATION':diagram(rng,accent,'constellation'),
        'SWATCHES':swatches,'CHANGELOG':changelog,'QUOTE':quote,'FLOW':flow,'GALLERY':gallery,'SCHEDULE':schedule,'CHECKLIST':checklist,'SIGNAL':signal,'INDEX_CARDS':cards,
        'CALCULATOR':'<div class="calculator"><label for="length">Length in millimetres</label><input id="length" type="number" data-convert value="25.4" step="0.1"><output data-converted aria-live="polite">1.0000 in</output><small>1 inch = 25.4 millimetres exactly.</small></div>',
        'GAUGE':'<svg class="dial" viewBox="0 0 250 180" role="img" aria-label="Illustrative reference dial"><path d="M30 145A95 95 0 0 1 220 145" stroke="currentColor" opacity=".3" stroke-width="10" fill="none"/><path d="M30 145A95 95 0 0 1 125 50" stroke="'+accent+'" stroke-width="10" fill="none"/><text x="125" y="145" text-anchor="middle" fill="currentColor" font-size="45" data-value>50</text></svg><small>Illustrative reference setting</small>',
        'FOOTER':esc(brand)+' · Independent reference notes · <a href="/">Home</a>'}
    template=(HERE/'templates'/family['template']).read_text(encoding='utf-8')
    slots=set(re.findall(r'\{\{([A-Z_]+)\}\}',template))
    if not slots <= values.keys(): raise ValueError('Unknown template slot')
    body=re.sub(r'\{\{([A-Z_]+)\}\}',lambda m:values[m.group(1)],template)
    # A real notes destination exists in every page, including short tools.
    body+='<section id="reference-notes" style="padding:20px 5vw"><details><summary>Reference note</summary><p>'+esc(facts[(page_index+2)%4])+'</p></details></section>'
    style=(HERE/'templates'/family['style']).read_text(encoding='utf-8')
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+esc(brand+' — '+title)+'</title><meta name="description" content="'+esc(intro)+'"><style>:root{--accent:'+accent+'}'+COMMON_CSS+style+'</style></head><body>'+body+'<script>'+SCRIPT+'</script></body></html>'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def atomic_json(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.cover-state-',dir=path.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as output:
            json.dump(value,output,indent=2); output.write('\n')
        os.chmod(tmp,0o600); os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def state_data(path):
    value=load_json(path)
    if value.get('owner')!=OWNER or value.get('schema')!=1 or not re.fullmatch(r'g-[a-f0-9]{16}',value.get('generation','')):
        raise ValueError('Unrecognised cover state')
    for name in value.get('files',{}):
        if name!='index.html' and not name.startswith('_lucx-cover/'+value['generation']+'/'):
            raise ValueError('Unexpected generated path')
        if '..' in PurePosixPath(name).parts or name.startswith('/'):
            raise ValueError('Unsafe generated path')
    if 'index.html' not in value.get('files',{}): raise ValueError('Cover state has no index')
    return value

def checked_path(root, relative):
    target=root/relative
    if any(p.is_symlink() for p in [root,target]+list(target.parents)[:len(PurePosixPath(relative).parts)]):
        raise ValueError('Symlink in generated cover path')
    if not target.resolve().is_relative_to(root.resolve()): raise ValueError('Path escapes web root')
    return target

def check(root,state):
    try:
        value=state_data(state)
        for name,expected in value['files'].items():
            path=checked_path(root,name)
            if not path.is_file() or sha(path)!=expected: return False
        return True
    except (OSError,ValueError,TypeError): return False

def cleanup(root,state):
    if not state.exists(): return
    value=state_data(state)
    folder=checked_path(root,'_lucx-cover/'+value['generation'])
    if folder.is_dir(): shutil.rmtree(folder)
    index=checked_path(root,'index.html')
    if index.is_file() and sha(index)==value['files']['index.html']: index.unlink()
    namespace=root/'_lucx-cover'
    if namespace.is_dir() and not namespace.is_symlink():
        try: namespace.rmdir()
        except OSError: pass
    state.unlink()

def generate(root,state,seed=None,family_id=None):
    if root.is_symlink(): raise ValueError('Web root is a symlink')
    manifest=load_json(HERE/'manifest.json')
    seed=seed or secrets.token_hex(24)
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',seed): raise ValueError('Invalid seed')
    rng=random.Random(seed)
    families=manifest['families']
    family=next((f for f in families if f['id']==family_id),None) if family_id else rng.choice(families)
    if family is None: raise ValueError('Unknown family')
    topics=load_json(HERE/'content'/'topics.json')
    group=family.get('topic_group','mixed')
    topic=rng.choice([t for t in topics if group=='mixed' or t.get('group')==group])
    vocabulary=load_json(HERE/'content'/'names.json')
    names={'first':rng.choice(vocabulary['first']),'last':rng.choice(vocabulary['last']),'accent':rng.choice(PALETTES)}
    pages=rng.randint(family['min_pages'],family['max_pages'])
    page_titles=['Overview']+['The reference','Working method','Observation records','Comparing results','Reading diagrams','Setup notes','Definitions','Interpretation','Session review','Field notes','Study index'][:pages-1]
    generation='g-'+hashlib.sha256((VERSION+seed+family['id']).encode()).hexdigest()[:16]
    root.mkdir(parents=True,exist_ok=True); os.chmod(root,0o755)
    namespace=checked_path(root,'_lucx-cover'); namespace.mkdir(exist_ok=True); os.chmod(namespace,0o755)
    final=checked_path(root,'_lucx-cover/'+generation)
    if final.exists():
        if state.exists() and check(root,state) and state_data(state)['generation']==generation: return state_data(state)
        raise ValueError('Generated directory already exists; choose a new seed')
    previous=state_data(state) if state.exists() else None
    staging=Path(tempfile.mkdtemp(prefix='.cover-build-',dir=namespace))
    temporary_index=None
    try:
        documents=[make_page(family,topic,names,rng,label,i,page_titles,generation) for i,label in enumerate(page_titles)]
        for i,document in enumerate(documents[1:],1):
            path=staging/f'page-{i:02d}.html'; path.write_text(document,encoding='utf-8'); os.chmod(path,0o644)
        os.chmod(staging,0o755)
        fd,tmp=tempfile.mkstemp(prefix='.cover-index-',dir=root); temporary_index=Path(tmp)
        with os.fdopen(fd,'w',encoding='utf-8') as output: output.write(documents[0])
        os.chmod(temporary_index,0o644)
        staging.rename(final)
        value={'owner':OWNER,'schema':1,'version':VERSION,'seed':seed,'family':family['id'],'brand':names['first']+' '+names['last'],'topic':topic['title'],'page_count':pages,'generation':generation,'files':{'index.html':sha(temporary_index)}}
        value['files'].update({p.relative_to(root).as_posix():sha(p) for p in final.iterdir() if p.is_file()})
        os.replace(temporary_index,root/'index.html'); temporary_index=None
        atomic_json(state,value)
        if previous and previous['generation']!=generation:
            old=checked_path(root,'_lucx-cover/'+previous['generation'])
            if old.is_dir(): shutil.rmtree(old)
        return value
    finally:
        if staging.exists(): shutil.rmtree(staging)
        if temporary_index and temporary_index.exists(): temporary_index.unlink()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['generate','ensure','check','cleanup','list'])
    parser.add_argument('--root',type=Path,default=Path('/var/www/html'))
    parser.add_argument('--state',type=Path,default=Path('/var/lib/lucx-ui-preinstall/cover-generator.json'))
    parser.add_argument('--seed'); parser.add_argument('--family')
    args=parser.parse_args()
    if args.action=='list':
        for family in load_json(HERE/'manifest.json')['families']:
            print(f'{family["id"]}: {family["min_pages"]}–{family["max_pages"]} pages')
        return 0
    if args.action=='check': return 0 if check(args.root,args.state) else 1
    if args.action=='cleanup': cleanup(args.root,args.state); return 0
    if args.action=='ensure' and check(args.root,args.state): return 0
    value=generate(args.root,args.state,args.seed,args.family)
    print(f'Cover: {value["brand"]} / {value["family"]}; {value["page_count"]} page(s).')
    return 0

if __name__=='__main__':
    try: raise SystemExit(main())
    except (OSError,ValueError,KeyError,TypeError) as exc:
        print('Cover generation failed:',exc,file=__import__('sys').stderr)
        raise SystemExit(1)
