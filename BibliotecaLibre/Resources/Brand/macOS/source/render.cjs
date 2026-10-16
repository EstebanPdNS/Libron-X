const fs=require('node:fs/promises'),path=require('node:path');
const {execFileSync}=require('node:child_process');
const sharp=require('/Users/esteban/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
const root=path.resolve(__dirname,'..');
(async()=>{
 for(const variant of ['Red','Black']){
 const name='LibronX-'+variant;
 const master=await fs.readFile(path.join(root,name+'.svg'));
 const iconset=path.join(root,name+'.iconset'),xc=path.join(root,name+'.appiconset');
 await fs.mkdir(iconset,{recursive:true});await fs.mkdir(xc,{recursive:true});
 const files=[],images=[];
 for(const size of [16,32,128,256,512])for(const scale of [1,2]){
  const name=`icon_${size}x${size}${scale===2?'@2x':''}.png`,pixels=size*scale;
  const bytes=await sharp(master,{density:144}).resize(pixels,pixels).toColourspace('srgb').png().toBuffer();
  await fs.writeFile(path.join(iconset,name),bytes);await fs.writeFile(path.join(xc,name),bytes);
  images.push({idiom:'mac',size:`${size}x${size}`,scale:`${scale}x`,filename:name});files.push({name,pixels});
 }
 await fs.writeFile(path.join(xc,'Contents.json'),JSON.stringify({images,info:{author:'xcode',version:1}},null,2)+'\n');
 const png=await sharp(master,{density:144}).resize(1024).png().toBuffer();await fs.writeFile(path.join(root,name+'-1024.png'),png);
 await sharp(master,{density:144}).resize(2048).png().toFile(path.join(root,name+'-2048.png'));
 await sharp({create:{width:900,height:900,channels:4,background:'#111214'}}).composite([{input:await sharp(master,{density:144}).resize(860).png().toBuffer(),left:20,top:12}]).png().toFile(path.join(root,name+'-preview.png'));
 const samples=[256,128,64,32,16];
 let x=32;const parts=[];
 for(const n of samples){parts.push({input:await sharp(master,{density:144}).resize(n).png().toBuffer(),left:x,top:20+Math.round((256-n)/2)});x+=n+20;}
 await sharp({create:{width:x+12,height:296,channels:4,background:'#202124'}}).composite(parts).png().toFile(path.join(root,name+'-sizes.png'));
 execFileSync('/usr/bin/iconutil',['--convert','icns','--output',path.join(root,name+'.icns'),iconset]);

 }
 const red=await fs.readFile(path.join(root,'LibronX-Red-1024.png')),black=await fs.readFile(path.join(root,'LibronX-Black-1024.png'));
 await sharp({create:{width:1200,height:660,channels:4,background:'#111214'}}).composite([{input:await sharp(red).resize(560).png().toBuffer(),left:20,top:30},{input:await sharp(black).resize(560).png().toBuffer(),left:620,top:30}]).png().toFile(path.join(root,'dos-iconos-macOS.png'));
 console.log('Rendered both native macOS icon families, all Retina sizes and comparison.');
})().catch(e=>{console.error(e);process.exit(1)});
