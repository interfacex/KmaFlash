"""One-time migration tool. Not used by the app at runtime. Never prints keys."""
import json, pathlib, sys, types
root = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(__file__).resolve().parents[1] / 'Sources/FlashCore/Resources'
for name, path in [('app', root/'kma-server/app'), ('app.reading', root/'kma-server/app/reading')]:
    mod = types.ModuleType(name); mod.__path__ = [str(path)]; sys.modules[name] = mod
from app.reading.personas import builtin_persona_specs, persona_dossier
from app.reading.persona_catalog import metadata
import app.reading.personas as p
p._turn_guidance = lambda profile, question: '安静相伴：先回答问题，默认简洁；每轮至多一个有意义的追问。'
people = []
for spec in builtin_persona_specs():
    name = spec['name']; meta = metadata(name); dossier = persona_dossier(name)
    people.append(dict(id=name, name=name, category=meta['category'], summary=spec['focus']+' · '+spec['style'], opening=spec['opening'], aliases=meta['aliases'], dossier=json.dumps(dossier,ensure_ascii=False,indent=2), systemPrompt=p.persona_prompt(name, spec)))
out.mkdir(parents=True,exist_ok=True)
(out/'personas.json').write_text(json.dumps(people, ensure_ascii=False, indent=2))
print(f'Migrated {len(people)} personas; model configurations are never imported.')
