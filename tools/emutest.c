#include "a64.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define NOINL __attribute__((noinline))
static int fetch(void*ctx,uint64_t p,void*o){mach_vm_size_t g=0;return mach_vm_read_overwrite(mach_task_self(),p,A64_PAGE,(mach_vm_address_t)o,&g)==KERN_SUCCESS;}
NOINL uint64_t t_fib(uint64_t n){return n<2?n:t_fib(n-1)+t_fib(n-2);}
NOINL uint64_t t_bits(uint64_t a,uint64_t b){uint64_t r=0;for(int i=0;i<64;i++){r^=(a>>i)&1?b<<(i%13):~b>>(i%7);r+=__builtin_popcountll(a^r);r=(r<<7)|(r>>57);r^=__builtin_clzll(r|1)*0x9e3779b97f4a7c15ull;r=__builtin_bswap64(r);r+=(uint32_t)r*(uint32_t)(a>>32);r-=(int32_t)b/((int32_t)(r|1));}return r;}
NOINL int64_t t_sdiv(int64_t a,int64_t b){int64_t s=0;for(int i=1;i<200;i++){s+=(a*i)/(b+i)-(a%(b+i));s^=s>>3;s+=((__int128)a*(s|1))>>64;s+=(unsigned __int128)(uint64_t)a*(uint64_t)s>>64;}return s;}
NOINL uint32_t t_w(uint32_t a,uint32_t b){uint32_t r=a;for(int i=0;i<500;i++){r=r*31+b;r^=r>>11;r+=(int16_t)r;r-=(int8_t)(r>>3);r=(r<<(i&31))|(r>>((32-i)&31));if((int32_t)r<0)r=~r;else r=-r;r+=(a>b)?i:-i;}return r;}
NOINL double t_fp(double a,double b){double s=0;for(int i=1;i<400;i++){s+=sqrt(a*i)/(b+i);s=s*0.75-floor(s)+ceil(a/i)-trunc(b/(i+1));s+=fabs(sin(0)+s)*0.001;if(s>1e6)s=-s/3;s+=(double)(int)(s*3.7)+(double)(uint32_t)(i*7);s=fmin(fmax(s,-1e7),1e7);s=a*b+s;}return s;}
NOINL float t_fps(float a,float b){float s=1;for(int i=1;i<400;i++){s=s*0.5f+a/(float)i-b*(float)(i%7);s=sqrtf(fabsf(s)+1);if(s<a)s+=b;s=(float)(long)(s*100)/100.0f;s=s*a+b;}return s;}
typedef struct{int id;double v;char n[12];short k;}rec;
NOINL int cmp(const void*x,const void*y){return ((const rec*)x)->id-((const rec*)y)->id;}
NOINL uint64_t t_sort(uint64_t seed){rec r[48];uint64_t x=seed;for(int i=0;i<48;i++){x=x*6364136223846793005ull+1442695040888963407ull;r[i].id=(int)(x>>40)%1000;r[i].v=(double)(x>>50)/3.0;r[i].k=(short)x;memset(r[i].n,'a'+(i%26),11);r[i].n[11]=0;}for(int i=1;i<48;i++){rec k=r[i];int j=i-1;while(j>=0&&r[j].id>k.id){r[j+1]=r[j];j--;}r[j+1]=k;}uint64_t h=0;for(int i=0;i<48;i++){h=h*131+r[i].id+(uint64_t)r[i].v+r[i].k+strlen(r[i].n)+(uint8_t)r[i].n[3];}return h;}
NOINL uint64_t t_str(const char*s){char b[256];strcpy(b,s);strcat(b,"-suffix");size_t n=strlen(b);for(size_t i=0;i<n/2;i++){char t=b[i];b[i]=b[n-1-i];b[n-1-i]=t;}uint64_t h=5381;for(size_t i=0;i<n;i++)h=h*33+(uint8_t)b[i];return h+(uint64_t)memcmp(b,s,3)+(strchr(b,'-')?1:0);}
NOINL uint64_t t_heap(uint64_t n){uint64_t*a=malloc(n*8);for(uint64_t i=0;i<n;i++)a[i]=i*i;a=realloc(a,n*16);for(uint64_t i=n;i<2*n;i++)a[i]=a[i-n]+1;uint64_t s=0;for(uint64_t i=0;i<2*n;i++)s+=a[i];free(a);return s;}
NOINL uint64_t t_vec(uint64_t seed){uint8_t a[64],b[64];uint32_t w[16];for(int i=0;i<64;i++){a[i]=(uint8_t)(seed>>(i%8)*8)+i;b[i]=(uint8_t)(i*3);}for(int i=0;i<64;i++)a[i]=(uint8_t)(a[i]+b[i])^0x5a;for(int i=0;i<16;i++)w[i]=(uint32_t)a[i*4]*3+a[i*4+1];uint64_t s=0;for(int i=0;i<16;i++)s+=w[i];for(int i=0;i<64;i++)if(a[i]>127)s+=a[i];float f[16];for(int i=0;i<16;i++)f[i]=(float)w[i]*0.25f;float t=0;for(int i=0;i<16;i++)t+=f[i];return s+(uint64_t)t;}
NOINL uint64_t t_atomic(uint64_t n){volatile uint64_t v=n;for(int i=0;i<50;i++){__atomic_fetch_add(&v,3,__ATOMIC_SEQ_CST);__atomic_fetch_and(&v,~1ull,__ATOMIC_ACQ_REL);__atomic_fetch_or(&v,4,__ATOMIC_RELAXED);uint64_t e=__atomic_load_n(&v,__ATOMIC_ACQUIRE);__atomic_compare_exchange_n(&v,&e,e*3,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE);__atomic_exchange_n(&v,e+1,__ATOMIC_SEQ_CST);}return __atomic_load_n(&v,__ATOMIC_SEQ_CST);}
int fails=0;
static void chk(const char*n,uint64_t nat,a64*c,a64_image*im,void*fn,uint64_t a0,uint64_t a1){a64_reset(c);a64_set_x(c,31,A64_STACK_TOP-0x1000);a64_set_x(c,30,A64_RETURN_SENTINEL);a64_set_x(c,0,a0);a64_set_x(c,1,a1);a64_status s=a64_run(c,(uint64_t)fn,500000000);uint64_t e=a64_get_x(c,0);int ok=s==A64_OK&&e==nat;if(!ok)fails++;printf("%-9s %s native=%016llx emu=%016llx steps=%llu st=%d",n,ok?"ok  ":"FAIL",nat,e,a64_steps(c),s);if(s)printf(" pc=%llx ins=%08x",a64_pc(c),a64_last_instruction(c));puts("");}
static void chkf(const char*n,double nat,a64*c,void*fn,double a,double b,int isf){a64_reset(c);a64_set_x(c,31,A64_STACK_TOP-0x1000);a64_set_x(c,30,A64_RETURN_SENTINEL);uint64_t ua,ub;if(isf){float fa=a,fb=b;uint32_t x,y;memcpy(&x,&fa,4);memcpy(&y,&fb,4);ua=x;ub=y;}else{memcpy(&ua,&a,8);memcpy(&ub,&b,8);}a64_set_v_low(c,0,ua);a64_set_v_low(c,1,ub);a64_status s=a64_run(c,(uint64_t)fn,500000000);uint64_t e=a64_get_v_low(c,0);double got;if(isf){float f;uint32_t u=e;memcpy(&f,&u,4);got=f;}else memcpy(&got,&e,8);int ok=s==A64_OK&&got==nat;if(!ok)fails++;printf("%-9s %s native=%.12g emu=%.12g steps=%llu st=%d",n,ok?"ok  ":"FAIL",nat,got,a64_steps(c),s);if(s)printf(" pc=%llx ins=%08x",a64_pc(c),a64_last_instruction(c));puts("");}
int main(){a64_image*im=a64_image_new(fetch,0);
#define S(sym,k) a64_image_add_stub(im,(uint64_t)dlsym(RTLD_DEFAULT,sym),k)
S("memcpy",A64_STUB_MEMCPY);S("memmove",A64_STUB_MEMCPY);S("memset",A64_STUB_MEMSET);S("bzero",A64_STUB_BZERO);S("__bzero",A64_STUB_BZERO);S("memcmp",A64_STUB_MEMCMP);S("memchr",A64_STUB_MEMCHR);S("strlen",A64_STUB_STRLEN);S("strcmp",A64_STUB_STRCMP);S("malloc",A64_STUB_MALLOC);S("calloc",A64_STUB_CALLOC);S("realloc",A64_STUB_REALLOC);S("free",A64_STUB_FREE);
a64*c=a64_new(im);
uint64_t vals[][2]={{3,5},{0x123456789abcdef0ull,0xfedcba9876543210ull},{7,0xffffffffull},{0xdeadbeefull,42}};
chk("fib",t_fib(24),c,im,t_fib,24,0);
for(int i=0;i<4;i++){chk("bits",t_bits(vals[i][0],vals[i][1]),c,im,t_bits,vals[i][0],vals[i][1]);chk("sdiv",t_sdiv((int64_t)vals[i][0],(int64_t)(vals[i][1]|1)),c,im,t_sdiv,vals[i][0],vals[i][1]|1);chk("w32",t_w((uint32_t)vals[i][0],(uint32_t)vals[i][1]),c,im,t_w,vals[i][0],vals[i][1]);chk("sort",t_sort(vals[i][0]),c,im,t_sort,vals[i][0],0);chk("vec",t_vec(vals[i][0]),c,im,t_vec,vals[i][0],0);chk("atomic",t_atomic(vals[i][0]),c,im,t_atomic,vals[i][0],0);}
chk("str",t_str("hello world"),c,im,t_str,(uint64_t)"hello world",0);
chk("heap",t_heap(1000),c,im,t_heap,1000,0);
double fv[][2]={{2.5,3.25},{1e3,0.125},{-7.75,12.5},{0.001,9999}};
for(int i=0;i<4;i++){chkf("fp",t_fp(fv[i][0],fv[i][1]),c,t_fp,fv[i][0],fv[i][1],0);chkf("fps",t_fps(fv[i][0],fv[i][1]),c,t_fps,fv[i][0],fv[i][1],1);}
printf("FAILURES: %d\n",fails);return fails!=0;}
